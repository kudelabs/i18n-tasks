# frozen_string_literal: true

module I18n::Tasks
  module Interpolations
    VARIABLE_REGEX = /%{[^}]+}/.freeze

    def inconsistent_interpolations(locales: nil, base_locale: nil) # rubocop:disable Metrics/AbcSize
      locales ||= self.locales
      base_locale ||= self.base_locale
      result = empty_forest

      data[base_locale].key_values.each do |key, value|
        next if !value.is_a?(String) || ignore_key?(key, :inconsistent_interpolations)

        base_vars = Set.new(value.scan(VARIABLE_REGEX))
        (locales - [base_locale]).each do |current_locale|
          node = data[current_locale].first.children[key]
          next unless node&.value.is_a?(String)

          if base_vars != Set.new(node.value.scan(VARIABLE_REGEX))
            result.merge!(node.walk_to_root.reduce(nil) { |c, p| [p.derive(children: c)] })
          end
        end
      end

      result.each { |root| root.data[:type] = :inconsistent_interpolations }
      result
    end
  end
end
