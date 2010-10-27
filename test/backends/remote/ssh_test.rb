require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'test_helper'))

class SshTest < ActiveSupport::TestCase
  def self.test_ssh?
    true unless ENV["TEST_SSH"] == "false"
  end
  
  if test_ssh? and
     File.exist? File.join( File.dirname(__FILE__),
                            "../../../../../../config/ssh.yml" )
    include BaseAttachmentTests
    attachment_model SshAttachment
  else
    def test_flunk_ssh
      puts "SSH config file not loaded, tests not running"
    end
  end
end
