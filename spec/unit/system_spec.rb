# Copyright (c) 2013-2016 SUSE LLC
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of version 3 of the GNU General Public License as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.   See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, contact SUSE LLC.
#
# To contact SUSE about this file by physical or electronic mail,
# you may find current contact information at www.suse.com

require_relative "spec_helper"

describe Machinery::System do
  include GivenFilesystemSpecHelpers
  use_given_filesystem

  describe ".for" do
    it "returns a LocalSystem when no hostname is given" do
      expect(Machinery::System.for(nil)).to be_a(Machinery::LocalSystem)
    end

    it "returns a RemoteSystem when a hostname is given" do
      allow_any_instance_of(Machinery::RemoteSystem).to receive(:connect)
      remote_system = Machinery::System.for("somehost", remote_user: "machinery")

      expect(remote_system).to be_a(Machinery::RemoteSystem)
      expect(remote_system.host).to eql("somehost")
      expect(remote_system.remote_user).to eq("machinery")
    end
  end

  describe "#check_retrieve_files_dependencies" do
    it "checks for the availibilty of rsync" do
      system = Machinery::System.new
      expect(system).to receive(:check_requirement).with("rsync", "--version")
      system.check_retrieve_files_dependencies
    end
  end

  describe "#check_create_archive_dependencies" do
    it "checks for the availibilty of tar and gzip" do
      system = Machinery::System.new
      expect(system).to receive(:check_requirement).with("tar", "--version")
      expect(system).to receive(:check_requirement).with("gzip", "--version")
      system.check_create_archive_dependencies
    end
  end

  describe "#create_archive" do
    it "creates an archive on LocalSystem" do
      dir = Dir.mktmpdir("machinery_unittest")
      test_dir = dir + "/test"
      md5_file = dir + "/md5"
      extract_dir = dir + "/extract"
      archive = dir + "/archive.tgz"

      FileUtils.cp_r("spec/data/system/archive_test", test_dir)

      filelist = Dir.glob(test_dir + "/*")

      local_system = Machinery::LocalSystem.new
      md5sum = local_system.run_command(
        ["find", test_dir, "-type", "f"],
        ["xargs", "md5sum"],
        stdout: :capture
      )
      File.write(md5_file, md5sum)
      lines = local_system.run_command(
        "find", test_dir,
        stdout: :capture
      )
      lines=lines.count("\n")

      local_system.create_archive(filelist,archive)

      expect(File.stat(archive).mode.to_s(8)[-3..-1]).to eq("600")
      FileUtils.mkdir(extract_dir)
      local_system.run_command( "tar", "--extract", "--gzip",
        "--directory=" + extract_dir,
        "--file=" + archive
      )
      test_lines = local_system.run_command(
        "find", extract_dir + test_dir,
        stdout: :capture
      )
      expect(test_lines.count("\n")).to eq(lines)

      md5sum.gsub!(/ \/tmp\//, " " + extract_dir + "/tmp/")
      local_system.run_command("md5sum", "-c", stdin: md5sum)
      FileUtils.rm_r(dir)
    end

    it "excludes excluded files", :with_temp_dir do
      archive = File.join(@tmp_dir, "/archive.tgz")
      test_dir = File.join(@tmp_dir, "/test")
      included_file = File.join(test_dir, "included")
      excluded_file_1 = File.join(test_dir, "excluded")
      excluded_file_2 = File.join(test_dir, "excluded?with special:chars")
      FileUtils.mkdir_p(test_dir)
      FileUtils.touch(included_file)
      FileUtils.touch(excluded_file_1)
      FileUtils.touch(excluded_file_2)

      local_system = Machinery::LocalSystem.new
      local_system.create_archive(test_dir, archive, [excluded_file_1, excluded_file_2])

      file_list = Machinery::Tarball.new(archive).list
      # paths in the tarball are relativ to "/", so we have to add it for the comparison
      paths = file_list.map { |f| File.join("/", f[:path]) }
      expect(paths).to match_array([test_dir, included_file])
    end

    it "doesn't log the commands" do
      system = Machinery::System.new
      expect(system).to receive(:run_command) do |*args|
        args.each do |arg|
          if arg.is_a?(Hash)
            expect(arg).to include(disable_logging: true)
          end
        end
      end
      system.create_archive([given_dummy_file], given_dummy_file("something.tgz"))
    end

    it "logs the file list", :with_temp_dir do
      archive = File.join(@tmp_dir, "/archive.tgz")

      system = Machinery::System.new
      allow(system).to receive(:run_command)
      expect(Machinery.logger).to receive(:info).with(
        "The following files are packaged in #{archive}: file1, file2"
      )
      system.create_archive(["file1", "file2"], archive)
    end
  end

  describe "#run_script" do
    it "reads the script from MACHINERY_ROOT/inspect_helpers/ and executes it" do
      begin
        FakeFS.activate!
        stub_const("Machinery::ROOT", "/")
        FileUtils.mkdir("/inspect_helpers")
        File.write("/inspect_helpers/foo", "ls /foo")

        system = Machinery::System.new
        expect(system).to receive(:run_command).
          with("bash", "-c", "ls /foo", stdout: :capture)

        system.run_script("foo", stdout: :capture)
      ensure
        FakeFS.deactivate!
      end
    end
  end

  describe "#run_script_with_progress" do
    it "calls the callback with the output" do
      system = Machinery::LocalSystem.new
      expect(system).to receive(:run_script) do |_script, options|
        options[:stdout].puts("output1")
        options[:stdout].puts("output2")
      end

      callback_buffer = ""
      system.run_script_with_progress("script") do |chunk|
        callback_buffer << chunk
      end

      expect(callback_buffer).to eq("output1\noutput2\n")
    end

    it "passes options to run_script" do
      system = Machinery::LocalSystem.new
      expect(system).to receive(:run_script).with("script", hash_including(:privileged))
      system.run_script_with_progress("script", privileged: true)
    end

    it "raises on errors" do
      system = Machinery::LocalSystem.new
      expect(system).to receive(:run_script).and_raise(
        Cheetah::ExecutionFailed.new(
          nil, double(exitstatus: 2), "", "script failed"
        )
      )
      expect {
        system.run_script_with_progress("script", privileged: true)
      }.to raise_error(
        Machinery::Errors::CommandFailed,
        /The required call 'script' does not seem to work as expected on the inspected system/
      )
    end
  end

  describe "#run_command_with_progress" do
    it "calls the callback with the output" do
      system = Machinery::LocalSystem.new
      expect(system).to receive(:run_command) do |_command, options|
        options[:stdout].puts("output1")
        options[:stdout].puts("output2")
      end

      callback_buffer = ""
      system.run_command_with_progress("command") do |chunk|
        callback_buffer << chunk
      end

      expect(callback_buffer).to eq("output1\noutput2\n")
    end

    it "passes options to run_command" do
      system = Machinery::LocalSystem.new
      expect(system).to receive(:run_command).
        with("command", "parameter", hash_including(:privileged))
      system.run_command_with_progress("command", "parameter", privileged: true)
    end

    it "raises on errors" do
      system = Machinery::LocalSystem.new
      expect(system).to receive(:run_command).with(
        "dpkg", "-V", hash_including(:privileged)
      ).and_raise(
        Cheetah::ExecutionFailed.new(
          nil, double(exitstatus: 2), "", "dpkg: unknown option -V"
        )
      )
      expect {
        system.run_command_with_progress("dpkg", "-V", privileged: true)
      }.to raise_error(
        Machinery::Errors::CommandFailed,
        /The required call 'dpkg -V' does not seem to work as expected on the inspected system/
      )
    end
  end

  describe "#has_command" do
    it "returns true if the system has the command" do
      system = Machinery::LocalSystem.new

      expect(system.has_command?("echo")).to be(true)
    end

    it "returns false if the system hasn't the command" do
      system = Machinery::LocalSystem.new

      expect(system.has_command?("not_existing_command")).to be(false)
    end
  end

  describe "#check_requirement" do
    let(:system) { Machinery::System.new }
    let(:command) { "cat" }

    it "raises an error if the command fails/doesn't exists" do
      expect(system).to receive(:run_command).with(command).and_raise(
        Cheetah::ExecutionFailed.new(nil, nil, nil, nil)
      )
      expect { system.check_requirement(command) }.to raise_error(
        Machinery::Errors::MissingRequirement,
        /Need the '#{command}' command to be available on the inspected system/
      )
    end

    it "returns the command if the exit code is 0" do
      expect(system).to receive(:run_command).with(command)
      expect(system.check_requirement(command)).to eq(command)
    end

    describe "it accepts an array of commands" do
      let(:command1) { "/bin/cat" }
      let(:command2) { "/usr/bin/cat" }
      let(:commands) { [command1, command2] }

      it "and raises if no one is executable" do
        expect(system).to receive(:run_command).with(command1).and_raise(
          Cheetah::ExecutionFailed.new(nil, nil, nil, nil)
        )
        expect(system).to receive(:run_command).with(command2).and_raise(
          Cheetah::ExecutionFailed.new(nil, nil, nil, nil)
        )

        expect { system.check_requirement(commands) }.to raise_error(
          Machinery::Errors::MissingRequirement,
          /Need the '#{command1}' or '#{command2}' commands to be available on the inspected system/
        )
      end

      it "does not raise if one is executable and returns it" do
        expect(system).to receive(:run_command).with(command1).and_raise(
          Cheetah::ExecutionFailed.new(nil, nil, nil, nil)
        )
        expect(system).to receive(:run_command).with(command2)

        expect(system.check_requirement(commands)).to eq(command2)
      end

      it "also does not return the parameters if one executable is executable" do
        parameters = ["--verbose", "--debug=true"]
        expect(system).to receive(:run_command).with(command1, *parameters).and_raise(
          Cheetah::ExecutionFailed.new(nil, nil, nil, nil)
        )
        expect(system).to receive(:run_command).with(command2, *parameters)

        expect(system.check_requirement(commands, *parameters)).to eq(command2)
      end
    end
  end

  describe "#arch" do
    it "returns the system's architecture" do
      system = Machinery::LocalSystem.new
      result = "x86_64"

      expect(system).to receive(:run_command).with(
        "uname", "-m", stdout: :capture).and_return(result)
      expect(system.arch).to eq(result)
    end
  end

  describe "#managed_files_database" do
    it "returns an RpmDatabase object on an RPM system" do
      system = Machinery::System.new
      allow(system).to receive(:has_command?).with("rpm").and_return(true)
      expect(system.managed_files_database).to be_a(Machinery::RpmDatabase)
    end

    it "returns a DpkgDatabase object on a Debian system" do
      system = Machinery::System.new
      allow(system).to receive(:has_command?).with("rpm").and_return(false)
      allow(system).to receive(:has_command?).with("dpkg").and_return(true)
      expect(system.managed_files_database).to be_a(Machinery::DpkgDatabase)
    end

    it "raises an error if neither rpm nor dpkg is on the system" do
      system = Machinery::System.new
      allow(system).to receive(:has_command?).with("rpm").and_return(false)
      allow(system).to receive(:has_command?).with("dpkg").and_return(false)

      expect {
        system.managed_files_database
      }.to raise_error(Machinery::Errors::MissingRequirement, /Need binary 'rpm' or 'dpkg'/)
    end
  end
end
