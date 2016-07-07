require 'i18n/tasks/scanners/ruby_ast_call_finder'
require 'parser/current'
require 'haml' rescue nil
require 'erb' rescue nil

module I18n::Tasks::Scanners
  class DefaultArgDetector
    include AST::Sexp

    attr_reader :path, :raw_key, :content, :file_type

    def initialize(path, raw_key, content)
      @path = path
      @raw_key = raw_key.to_s
      @content = content
      @file_type = File.extname(path)
    end

    def detect
      begin
        default_arg = case file_type
                      when '.haml'
                        find_by_ruby_ast ::Haml::Engine.new(content.gsub(/^\s*/, '')).precompiled
                      when '.erb'
                        find_by_ruby_ast ERB.new(content).src
                      when '.js'
                        content.scan(/I18n.t\([^,]+,\s*{\s*defaultValue: `([^`]+)`/).flatten.first
                      else
                        puts "Warning: Not supported file type:"
                        puts " File:    #{path}"
                        puts " Content: #{content.lstrip}"
                        puts ''
                        return
                      end

        if default_arg.nil?
          puts "Warning: Unable to recognize default arg:"
          puts "  File:    #{path}"
          puts "  Content: #{content.lstrip}"
          puts ''
        end

        default_arg
      rescue => e
        puts "Error: Exception raised:"
        puts "  File: #{path}"
        puts "  Content: #{content}"
        puts "  #{e.message}"
        puts ''
      end
    end

    def find_by_ruby_ast(src)
      nodes = ::Parser::CurrentRuby.parse(src)
      finder = I18n::Tasks::Scanners::RubyAstCallFinder.new(messages: %i(t translate), receivers: [nil, s(:const, nil, :I18n)])

      finder.collect_calls(nodes) do |send_node, _method_name|
        next if send_node.children[2].children[0].to_s != raw_key

        args = send_node.children[3]
        if args.type == :hash
          pair_node = args.children.find do |pair|
            if pair.type == :pair
              key_node = pair.children[0]
              %i(sym str).include?(key_node.type) && key_node.children[0].to_s == 'default'
            end
          end

          pair_node && pair_node.children.last.children[0]
        end
      end.first
    end
  end
end
