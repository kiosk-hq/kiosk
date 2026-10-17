# frozen_string_literal: true

require 'open3'

# The tracked runtime Ruby files of the demos: `app/`, `config/`, and `lib/`
# without `lib/tasks/`.
module DemoRuntimeFiles
  REPO_ROOT = File.expand_path('../../..', __dir__)

  module_function

  # [git succeeded?, the sorted relative paths]
  def list
    tracked, status = Open3.capture2('git', '-C', REPO_ROOT, 'ls-files', 'kiosk-demo-*')
    files = tracked.lines(chomp: true).select do |f|
      f.end_with?('.rb') && f.match?(%r{\Akiosk-demo-[a-z0-9_]+/(app|config|lib)/}) &&
        !f.match?(%r{\Akiosk-demo-[a-z0-9_]+/lib/tasks/})
    end
    [status.success?, files.sort.freeze]
  end

  # The demo directory names the files cover.
  def demos(files) = files.map { |f| f[/\Akiosk-demo-[a-z0-9_]+/] }.uniq
end
