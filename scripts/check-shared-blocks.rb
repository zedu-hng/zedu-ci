# Fails when copies of a shared block differ. A block sits between "# shared:<name> begin" and
# "# shared:<name> end" comment lines in .github/workflows/*.yml; every copy of a name must match
# exactly once each copy's own indentation is removed. GitHub can't share code between steps of
# separately pinned workflows, so the copies are kept identical here instead.
# Usage: ruby scripts/check-shared-blocks.rb

blocks = Hash.new { |h, k| h[k] = [] }
errors = []

Dir[".github/workflows/*.yml"].sort.each do |file|
  open_block = nil
  lines = []
  File.readlines(file).each_with_index do |line, i|
    if (m = line.match(/^\s*# shared:([a-z0-9-]+) (begin|end)\s*$/))
      name, edge = m[1], m[2]
      if edge == "begin"
        errors << "#{file}:#{i + 1}: shared:#{name} begins inside shared:#{open_block[:name]}" if open_block
        open_block = { name: name, line: i + 1 }
        lines = []
      elsif open_block.nil? || open_block[:name] != name
        errors << "#{file}:#{i + 1}: shared:#{name} ends without a begin"
      else
        indent = lines.reject { |l| l.strip.empty? }.map { |l| l[/^ */].size }.min || 0
        text = lines.map { |l| l.strip.empty? ? "\n" : l[indent..] }.join
        blocks[name] << { file: "#{file}:#{open_block[:line]}", text: text }
        open_block = nil
      end
    elsif open_block
      lines << line
    end
  end
  errors << "#{file}: shared:#{open_block[:name]} never ends" if open_block
end

blocks.each do |name, copies|
  if copies.size < 2
    errors << "shared:#{name} has one copy (#{copies[0][:file]}); remove the markers or add the other copy"
    next
  end
  reference = copies.first
  differing = copies.drop(1).reject { |copy| copy[:text] == reference[:text] }
  differing.each do |copy|
    errors << "shared:#{name} differs: #{copy[:file]} vs #{reference[:file]}. Change every copy together."
  end
  puts "shared:#{name}: #{copies.size} copies match (#{copies.map { |c| c[:file] }.join(", ")})" if differing.empty?
end

if errors.any?
  errors.each { |e| puts "::error::#{e}" }
  exit 1
end
