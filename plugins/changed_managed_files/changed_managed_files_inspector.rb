# Copyright (c) 2013-2015 SUSE LLC
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

class ChangedManagedFilesInspector < Inspector
  has_priority 90

  def initialize(system, description)
    @system = system
    @description = description
  end

  def inspect(filter, options = {})
    system.check_requirement("find", "--version")
    system.check_retrieve_files_dependencies if options[:extract_changed_managed_files]

    @system = system

    scope = ChangedManagedFilesScope.new
    file_store = @description.scope_file_store("changed_managed_files")
    scope.scope_file_store = file_store

    result = changed_files

    if filter
      file_filter = filter.element_filter_for("/changed_managed_files/files/name")
      result.delete_if { |e| file_filter.matches?(e.name) } if file_filter
    end

    file_store.remove
    if options[:extract_changed_managed_files]
      file_store.create

      existing_files = result.reject do |f|
        f.changes.nil? ||
        f.changes.include?("deleted") ||
        f.link? ||
        f.directory? ||
        f.name == "/"
      end

      scope.retrieve_files_from_system(@system, existing_files.map(&:name))
    end

    scope.extracted = !!options[:extract_changed_managed_files]
    scope.files = ChangedManagedFileList.new(result.sort_by(&:name))

    @description["changed_managed_files"] = scope
  end

  def summary
    "#{@description.changed_managed_files.extracted ? "Extracted" : "Found"} " +
      "#{@description.changed_managed_files.files.count} changed files."
  end

  private

  def amend_file_attributes(changed_files)
    existing_files = changed_files.reject { |f| f.changes.nil? || f.changes.include?("deleted") }
    file_attributes = @system.rpm_database.get_path_data(existing_files.map(&:name))
    changed_files.map do |changed_file|
      if file_attributes[changed_file.name]
        ChangedManagedFile.new(changed_file.attributes.merge(file_attributes[changed_file.name]))
      else
        changed_file
      end
    end
  end

  def changed_files
    file_list = @system.rpm_database.changed_files.reject { |f| f.config_file? }.map do |file|
      ChangedManagedFile.new(file.attributes)
    end
    amend_file_attributes(file_list)
  end
end
