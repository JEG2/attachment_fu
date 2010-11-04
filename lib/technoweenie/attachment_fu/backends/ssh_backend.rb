module Technoweenie # :nodoc:
  module AttachmentFu # :nodoc:
    module Backends
      # Methods for SSH/SCP backed attachments (uploaded to a media server).
      module SshBackend
        # A global ID cycled 1 to 4 for asset URL's.
        def self.cycled_asset_id
          @cycled_asset_id ||= -1
          @cycled_asset_id  += 1
          @cycled_asset_id  %  4 + 1
        end
        
        def self.included(base) #:nodoc:
          begin
            require "net/ssh"
          rescue LoadError
            raise RequiredLibraryNotFoundError.
                  new("Net::SSH could not be loaded")
          end
          begin
            require "net/scp"
          rescue LoadError
            raise RequiredLibraryNotFoundError.
                  new("Net::SCP could not be loaded")
          end

          class << base
            attr_accessor :ssh_config
          end
          begin
            ssh_config_path = base.attachment_options.fetch(
                                :ssh_config_path,
                                "#{RAILS_ROOT}/config/ssh.yml"
                              )
            base.ssh_config = YAML.load(
                                 ERB.new(File.read(ssh_config_path)).result
                               )[RAILS_ENV].symbolize_keys
          rescue
            # raise ConfigFileNotFoundError.
            #       new("File %s not found" % @@ssh_config_path)
          end

          base.before_update :rename_file
        end
      
        # Gets the full path to the filename (on the server) in this format:
        #
        #   # This assumes a model name like MyModel
        #   ssh_config_dir/my_models/0000/0005/blah.jpg
        #
        # The optional thumbnail argument will output the thumbnail's filename.
        def full_filename(thumbnail = nil)
          File.join( *[ self.class.ssh_config[:directory],
                        base_path(thumbnail ? thumbnail_class : self),
                        thumbnail_name_for(thumbnail) ].compact )
        end
        
        # The pseudo hierarchy containing the file relative to the SSH
        # directory.  Example:  <tt>:table_name/:partitioned_id</tt>.
        # 
        # If a block is passed, each chunk of the path filtered through that
        # block for escaping.
        def base_path(prefix_class = self, &escape)
          escape ||= lambda { |path| path }
          File.join( *[ prefix_class.attachment_options[:path_prefix].to_s,
                        *partitioned_id ].map(&escape) )
        end

        # The attachment ID used in the full path of a file.
        def attachment_path_id
          ((respond_to?(:parent_id) and parent_id) or id) or 0
        end
              
        # Partitions the ID into an array of path components.
        #
        # For example, given an ID of 1, it will return
        # <tt>["0000", "0001"]</tt>.
        #
        # If the id is not an integer, then path partitioning will be performed
        # by hashing the string value of the id with SHA-512, and splitting the
        # result into four components. If the id a 128-bit UUID (as set by
        # <tt>:uuid_primary_key => true</tt>) then it will be split into two
        # components.
        # 
        # To turn this off entirely, set <tt>:partition => false</tt>.
        def partitioned_id
          if respond_to?(:attachment_options) and
             attachment_options[:partition] == false 
            [ ]
          elsif attachment_options[:uuid_primary_key]
            # Primary key is a 128-bit UUID in hex format.
            # Split it into 2 components.
            path_id    = attachment_path_id.to_s
            component1 = path_id[0..15]  || "-"
            component2 = path_id[16..-1] || "-"
            [component1, component2]
          else
            path_id = attachment_path_id
            if path_id.is_a?(Integer)
              # Primary key is an integer. Split it after padding it with 0.
              ("%08d" % path_id).scan(/..../)
            else
              # Primary key is a String. Hash it and split it into 4 components.
              hash = Digest::SHA512.hexdigest(path_id.to_s)
              [hash[0..31], hash[32..63], hash[64..95], hash[96..127]]
            end
          end
        end
        
        # Gets the public path to the file (based on the URL from the SSH
        # config.)  The optional thumbnail argument will output the thumbnail's
        # filename.
        # 
        # If the SSH URL includes includes a %d, it will be replaced with
        # cycling ID's from 1-4.
        def public_filename(thumbnail = nil)
          [ self.class.ssh_config[:url].to_s %
            Technoweenie::AttachmentFu::Backends::SshBackend.cycled_asset_id,
            base_path(thumbnail ? thumbnail_class : self) { |path|
              ERB::Util.url_encode(path)
            },
            ERB::Util.url_encode(thumbnail_name_for(thumbnail)) ].
          reject(&:blank?).join("/")
        end
           
        # Overwrites the base filename writer in order to store the old
        # filename.
        def filename=(value)
          @old_filename = full_filename unless filename.nil? or @old_filename
          write_attribute :filename, sanitize_filename(value)
        end

        protected

          # Destroys the file.  Called in the after_destroy() callback.
          def destroy_file
            start_ssh do |ssh|
              ssh.exec!("rm #{e full_filename}")
              dir = File.dirname(full_filename)
              ssh.exec!("find #{e dir} -maxdepth 0 -empty -exec rm -r {} \\;")
              dir = File.dirname(dir)
              ssh.exec!("find #{e dir} -maxdepth 0 -empty -exec rm -r {} \\;")
            end
          end
          
          # Renames the given file before saving.
          def rename_file
            return unless @old_filename and @old_filename != full_filename
            start_ssh do |ssh|
              if save_attachment?
                ssh.exec!("rm #{e @old_filename}")
              else
                ssh.exec!("mv #{e @old_filename} #{e full_filename}")
              end
            end
            @old_filename =  nil
            true
          end
          
          # Saves the file to the file system.
          def save_to_storage
            if save_attachment?
              start_ssh do |ssh|
                ssh.exec!("mkdir -p #{e File.dirname(full_filename)}")
                ssh.scp.upload!(temp_path, full_filename)
                ssh.exec!( "chmod #{attachment_options.fetch(:chmod, '0644')}" +
                           " #{e full_filename}" )
              end
            end
            @old_filename = nil
            true
          end
          
          # Opens an SSH connection to the server based on the configured
          # settings.
          def start_ssh(&session)
            config = self.class.ssh_config
            Net::SSH.start( config[:host],
                            config[:user],
                            config.fetch(:options, { }),
                            &session )
          end
          
          # Escape the passed content before handing it to the shell.
          def e(str)
            str.to_s.gsub(/(?=[^a-zA-Z0-9_.\/\-\x7F-\xFF\n])/n, '\\').
                     gsub(/\n/,                                 "'\n'").
                     sub(/^$/,                                  "''")
          end
          
          # Returns the current contents of the file.
          def current_data
            start_ssh do |ssh|
              return ssh.scp.download!(full_filename)
            end
          end
      end
    end
  end
end
