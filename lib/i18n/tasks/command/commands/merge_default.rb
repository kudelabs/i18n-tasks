# frozen_string_literal: true
require 'i18n/tasks/command/collection'

module I18n::Tasks
  module Command
    module Commands
      module MergeDefault
        include Command::Collection

        cmd :merge_default,
          pos:  '[locale ...]',
          desc: 'Merge default value to locale files',
          args: [:locales, :out_format, arg(:value) + [{default: '%{value_or_default_or_human_key}'}],
                 ['--nil-value', 'Set value to nil. Takes precedence over the value argument.']]

        def merge_default(opt = {})
          added   = i18n.empty_forest
          locales = (opt[:locales] || i18n.locales)
          value   = opt[:'nil-value'] ? nil : opt[:value]

          forest = i18n.missing_diff_forest(locales, i18n.base_locale).set_each_value!(value)
          i18n.data.merge! forest
          added.merge! forest

          forest = i18n.used_tree(strict: true).select_keys do |key, node|
            current = i18n.t(key, i18n.base_locale)
            default = (node.data[:occurrences] || []).detect { |o| o.default_arg.presence }.try(:default_arg)

            next false if default.nil?

            if default.is_a?(Hash)
              if default.all? { |k, _| I18n::Tasks::PluralKeys::PLURAL_KEY_SUFFIXES.include? k.to_s }
                unless current.is_a?(Hash) && default.all? { |k, v| current[k.to_s] == v }
                  puts "Warning: Default value of plural key changed, Please update yml with following content(below '---') manually:"
                  puts ({ key => default }).to_yaml
                  puts ""
                end
                next false
              end
            end

            if current && !current.is_a?(String)
              puts "Warning: Value in #{i18n.base_locale}.yml is not a String:"
              puts "  Key: #{key}"
              puts "  Value in YAML: #{current}"
              puts "  Default Value: #{default}"
              puts ""
            end

            current != default
          end.set_root_key!(i18n.base_locale).set_each_value!(value)
          i18n.data.merge! forest

          changed_keys = forest.keys.to_a.map &:first
          (locales - [i18n.base_locale]).inject(forest) do |forest, locale|
            locale_forest = i18n.data[i18n.base_locale].select_keys do |key, node|
              changed_keys.include? key
              #key = i18n.depluralize_key(key, i18n.base_locale)
              #default = i18n.t(key, i18n.base_locale)
              #current = i18n.t(key, locale)
              #default.present? && (current != default)
            end.set_root_key!(locale).keys do |key, node|
              data = {locale: locale, missing_diff_locale: node.data[:locale]}
              if node.data.key?(:path)
                data[:path] = LocalePathname.replace_locale(node.data[:path], node.data[:locale], locale)
              end
              node.data.update data
            end

            forest.merge! locale_forest
          end

          i18n.data.merge! forest
          added.merge! forest
          log_stderr "Merge #{added.leaves.count} keys"
          print_forest added, opt
        end
      end
    end
  end
end
