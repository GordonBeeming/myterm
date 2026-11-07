#!/usr/bin/env ruby
# Exercise the checked-in path filters without GitHub credentials or a release.
require 'yaml'

ROOT = File.expand_path('..', __dir__)
MATCH_FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH

def events(name)
  workflow = YAML.load_file(File.join(ROOT, '.github', 'workflows', name))
  workflow.fetch('on') { workflow.fetch(true) }
end

def matches?(pattern, path)
  # GitHub's trailing ** includes descendants; Ruby needs a final path component.
  glob = pattern.end_with?('**') ? "#{pattern}/*" : pattern
  File.fnmatch?(glob, path, MATCH_FLAGS)
end

def accepts?(event, paths)
  raise 'An event cannot combine paths and paths-ignore' if event.key?('paths') && event.key?('paths-ignore')

  if event.key?('paths-ignore')
    return paths.any? do |path|
      event.fetch('paths-ignore').none? { |pattern| matches?(pattern, path) }
    end
  end

  return true unless event.key?('paths')

  paths.any? do |path|
    included = false
    event.fetch('paths').each do |pattern|
      negative = pattern.start_with?('!')
      glob = negative ? pattern[1..-1] : pattern
      included = !negative if matches?(glob, path)
    end
    included
  end
end

checks = 0
docs = ['README.md', 'AGENTS.md', 'docs/research/notes.md',
        'docs/planning/prototype.html', 'Services/relay/README.md',
        'Packages/MyTermRemote/design.rst', 'Companion/help.mdx', 'LICENSE']
sources = {
  'beta.yml' => ['push', 'Sources/MyTerm/App.swift'],
  'build.yml' => ['pull_request', 'Sources/MyTerm/App.swift'],
  'companion.yml' => ['pull_request', 'Companion/App.swift'],
  'relay-release.yml' => ['push', 'Services/relay/internal/auth/auth.go']
}

sources.each do |name, (event_name, source)|
  triggers = events(name)
  %w[push pull_request].each do |event|
    next unless triggers.key?(event)

    docs.each do |path|
      raise "#{name} #{event} runs for documentation: #{path}" if accepts?(triggers.fetch(event), [path])
      checks += 1
    end
    raise "#{name} #{event} runs for combined documentation" if accepts?(triggers.fetch(event), docs)
    checks += 1
  end
  raise "#{name} skips product source" unless accepts?(triggers.fetch(event_name), [source])
  raise "#{name} skips mixed source and documentation" unless accepts?(triggers.fetch(event_name), docs + [source])
  checks += 2
end

beta = events('beta.yml')
raise 'Manual beta rebuild is missing' unless beta.key?('workflow_dispatch')
raise 'Workflow-only changes publish a beta' if accepts?(beta.fetch('push'), ['.github/workflows/beta.yml'])
raise 'Test-only changes publish a beta' if accepts?(beta.fetch('push'), ['Tests/CoreTests.swift', 'script/test_workflow_paths.rb'])
raise 'Release packaging no longer publishes a beta' unless accepts?(beta.fetch('push'), ['Packaging/Info.plist'])
raise 'Runtime build scripts no longer publish a beta' unless accepts?(beta.fetch('push'), ['script/build_and_run.sh'])
%w[build.yml relay-release.yml].each do |name|
  raise "#{name} lost its release trigger" unless events(name).key?('release')
end
puts "Passed #{checks + 7} workflow path and trigger checks."
