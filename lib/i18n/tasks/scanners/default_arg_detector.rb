require 'i18n/tasks/scanners/ruby_ast_call_finder'
require 'parser/current'
require 'haml' rescue nil
require 'erb' rescue nil

require 'execjs'
ExecJS.runtime = ExecJS::Runtimes::Node

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
                        matched = find_by_js_regexp(content)
                        return if matched.nil? && content !~ /I18n.t/ #not translation in JS
                        matched
                      else
                        puts "Warning: Not supported file type:"
                        puts " File:    #{path}"
                        puts " Content: #{content.lstrip}"
                        puts ''
                        return
                      end

        #if default_arg.nil?
          #puts "Warning: Unable to recognize default arg:"
          #puts "  File:    #{path}"
          #puts "  Content: #{content.lstrip}"
          #puts ''
        #end

        default_arg
      rescue => e
        puts "Error: Exception raised:"
        puts "  File: #{path}"
        puts "  Content: #{content}"
        puts "  #{e.message}"
        puts ''
      end
    end

    # I18n.t("msg.show", { defaultValue: "MSG SHOW" })
    # I18n.t("msg.count", { defaultValue: { one: "1 MSG", other: "%{count} MSGS" }})
    def find_by_js_regexp(content)
      matched = content.scan(/I18n.t\([^,]+,\s*{\s*defaultValue:\s*(?:`([^`]+)`|"([^"]+)"|'([^']+)')/).flatten.compact.first

      if matched.nil?
        matched = content.scan(/I18n.t\([^,]+,\s*{\s*defaultValue:\s*({.+})/).flatten.compact.first
        if matched
          openBr = 0
          text = ''
          matched.each_char do |char|
            case char
            when "{"
              openBr += 1
            when "}"
              openBr -= 1
            end
            text << char
            break if openBr == 0
          end

          matched = ExecJS.eval text
        end
      end

      matched
    end

    # s(:send,
    #   s(:const, nil, :I18n), :t,
    #   s(:str, "msg.sent_time"),
    #   s(:hash,
    #     s(:pair,
    #       s(:sym, :default),
    #       s(:str, "msg sent %{time}"))))
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

          if pair_node
            default = pair_node.children.last
            if default.type == :hash
              default.children.inject({}) do |h, pair|
                key = pair.children[0].children[0]
                value = pair.children[1].children[0]
                h[key] = value
                h
              end
            else
              default.children[0]
            end
          end
        end
      end.first
    end
  end
end
