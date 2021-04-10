# frozen_string_literal: true
require 'set'
require 'i18n/tasks/split_key'
require 'i18n/tasks/data/tree/nodes'
require 'i18n/tasks/data/tree/node'

module I18n::Tasks::Data::Tree
  # Siblings represents a subtree sharing a common parent
  # in case of an empty parent (nil) it represents a forest
  # siblings' keys are unique
  class Siblings < Nodes
    include ::I18n::Tasks::SplitKey

    attr_reader :parent, :key_to_node

    def initialize(opts = {})
      super(nodes: opts[:nodes])
      @parent = opts[:parent] || first.try(:parent)
      @list.map! { |node| node.parent == @parent ? node : node.derive(parent: @parent) }
      @key_to_node = @list.inject({}) { |h, node| h[node.key] = node; h }
    end

    def attributes
      super.merge(parent: @parent)
    end

    def rename_key(key, new_key)
      node = key_to_node.delete(key)
      replace_node! node, node.derive(key: new_key)
      self
    end

    def rename_each_key!(full_key_pattern, new_key_tpl)
      pattern_re = I18n::Tasks::KeyPatternMatching.compile_key_pattern(full_key_pattern)
      nodes do |node|
        next if node.full_key(root: true) !~ pattern_re
        new_key = new_key_tpl.gsub('%{key}', node.key)
        if node.parent == parent
          rename_key(node.key, new_key)
        else
          node.parent.children.rename_key(node.key, new_key)
        end
      end
      self
    end

    def replace_node!(node, new_node)
      @list[@list.index(node)]  = new_node
      key_to_node[new_node.key] = new_node
    end

    # @return [Node] by full key
    def get(full_key)
      first_key, rest = split_key(full_key.to_s, 2)
      node            = key_to_node[first_key]
      if rest && node
        node = node.children.try(:get, rest)
      end
      node
    end

    alias [] get

    # add or replace node by full key
    def set(full_key, node)
      raise 'value should be a I18n::Tasks::Data::Tree::Node' unless node.is_a?(Node)
      key_part, rest = split_key(full_key, 2)
      child          = key_to_node[key_part]
      
      # Otherwise the order of keys will determine whether or not we get a warning.
      if child && child.children.any?{|c| c.full_key == full_key}
        warn_add_leaf_at_branch(full_key)
      end

      if rest
        unless child
          child = Node.new(key: key_part, parent: parent, children: [])
          append! child
        end
        unless child.children
          warn_add_children_to_leaf child
          child.children = []
        end
        child.children.set rest, node
      else
        remove! child if child
        append! node
      end
      dirty!
      node
    end

    alias []= set


    # methods below change state

    def remove!(node)
      super
      key_to_node.delete(node.key)
      self
    end

    def append!(nodes)
      nodes = nodes.map do |node|
        raise "already has a child with key '#{node.key}'" if key_to_node.key?(node.key)
        key_to_node[node.key] = (node.parent == parent ? node : node.derive(parent: parent))
      end
      super(nodes)
      self
    end

    def append(nodes)
      derive.append!(nodes)
    end

    # @param on_leaves_merge [Proc] invoked when a leaf is merged with another leaf
    def merge!(nodes, on_leaves_merge: nil)
      nodes = Siblings.from_nested_hash(nodes) if nodes.is_a?(Hash)
      nodes.each do |node|
        merge_node! node, on_leaves_merge: on_leaves_merge
      end
      self
    end

    def merge(nodes)
      derive.merge!(nodes)
    end

    def subtract_keys(keys)
      remove_nodes_and_emptied_ancestors(keys.inject(Set.new) { |set, key| (node = get(key)) ? set << node : set })
    end

    def subtract_keys!(keys)
      remove_nodes_and_emptied_ancestors!(keys.inject(Set.new) { |set, key| (node = get(key)) ? set << node : set })
    end

    def subtract_by_key(other)
      subtract_keys other.key_names(root: true)
    end

    def subtract_by_key!(other)
      subtract_keys! other.key_names(root: true)
    end

    def set_root_key!(new_key, data = nil)
      return self if empty?
      rename_key first.key, new_key
      leaves { |node| node.data.merge! data } if data
      self
    end

    # @param on_leaves_merge [Proc] invoked when a leaf is merged with another leaf
    def merge_node!(node, on_leaves_merge: nil)
      if key_to_node.key?(node.key)
        our = key_to_node[node.key]
        return if our == node
        our.value = node.value if node.leaf?
        our.data.merge!(node.data) if node.data?

        our.children = nil if node.leaf? && our.children

        if node.children?
          if our.children
            our.children.merge!(node.children)
          else
            warn_add_children_to_leaf our
            our.children = node.children
          end
        elsif on_leaves_merge
          on_leaves_merge.call(our, node)
        end
      else
        @list << (key_to_node[node.key] = node.derive(parent: parent))
        dirty!
      end
    end

    # @param nodes [Enumerable] Modified in-place.
    def remove_nodes_and_emptied_ancestors(nodes)
      add_ancestors_that_only_contain_nodes! nodes
      select_nodes { |node| !nodes.include?(node) }
    end

    # @param nodes [Enumerable] Modified in-place.
    def remove_nodes_and_emptied_ancestors!(nodes)
      add_ancestors_that_only_contain_nodes! nodes
      select_nodes! { |node| !nodes.include?(node) }
    end

    private

    # Adds all the ancestors that only contain the given nodes as descendants to the given nodes.
    # @param nodes [Set] Modified in-place.
    def add_ancestors_that_only_contain_nodes!(nodes)
      levels.reverse_each do |level_nodes|
        level_nodes.each { |node| nodes << node if node.children? && node.children.all? { |c| nodes.include?(c) } }
      end
    end

    def warn_add_children_to_leaf(node)
      ::I18n::Tasks::Logging.log_warn "'#{node.full_key}' was a leaf, now has children (value <- scope conflict)"
    end
    
    def warn_add_leaf_at_branch(full_key)
      ::I18n::Tasks::Logging.log_warn "'#{full_key}' was a branch, now is being treated as a leaf (value <- scope conflict)"
    end

    class << self
      include ::I18n::Tasks::SplitKey

      def null
        new
      end

      def build_forest(opts = {}, &block)
        opts[:nodes] ||= []
        parse_parent_opt!(opts)
        forest = Siblings.new(opts)
        block.call(forest) if block
        # forest.parent.children = forest
        forest
      end

      # @param key_occurrences [I18n::Tasks::Scanners::KeyOccurrences]
      # @return [Siblings]
      def from_key_occurrences(key_occurrences)
        build_forest do |forest|
          key_occurrences.each do |key_occurrence|
            forest[key_occurrence.key] = ::I18n::Tasks::Data::Tree::Node.new(
                key:  split_key(key_occurrence.key).last,
                data: {occurrences: key_occurrence.occurrences})
          end
        end
      end

      def from_key_attr(key_attrs, opts = {}, &block)
        build_forest(opts) { |forest|
          key_attrs.each { |(full_key, attr)|
            raise "Invalid key #{full_key.inspect}" if full_key.end_with?('.')
            node = ::I18n::Tasks::Data::Tree::Node.new(attr.merge(key: split_key(full_key).last))
            block.call(full_key, node) if block
            forest[full_key] = node
          }
        }
      end

      def from_key_names(keys, opts = {}, &block)
        build_forest(opts) { |forest|
          keys.each { |full_key|
            node = ::I18n::Tasks::Data::Tree::Node.new(key: split_key(full_key).last)
            block.call(full_key, node) if block
            forest[full_key] = node
          }
        }
      end

      # build forest from nested hash, e.g. {'es' => { 'common' => { name => 'Nombre', 'age' => 'Edad' } } }
      # this is the native i18n gem format
      def from_nested_hash(hash, opts = {})
        parse_parent_opt!(opts)
        raise ::I18n::Tasks::CommandError.new("invalid tree #{hash.inspect}") unless hash.respond_to?(:map)
        opts[:nodes] = hash.map { |key, value| Node.from_key_value key, value }
        Siblings.new(opts)
      end

      alias [] from_nested_hash

      # build forest from [[Full Key, Value]]
      def from_flat_pairs(pairs)
        Siblings.new.tap do |siblings|
          pairs.each { |full_key, value|
            siblings[full_key] = ::I18n::Tasks::Data::Tree::Node.new(key: split_key(full_key).last, value: value)
          }
        end
      end

      private
      def parse_parent_opt!(opts)
        if opts[:parent_key]
          opts[:parent] = ::I18n::Tasks::Data::Tree::Node.new(key: opts[:parent_key])
        end
        if opts[:parent_attr]
          opts[:parent] = ::I18n::Tasks::Data::Tree::Node.new(opts[:parent_attr])
        end
        if opts[:parent_locale]
          opts[:parent] = ::I18n::Tasks::Data::Tree::Node.new(
              key: opts[:parent_locale], data: {locale: opts[:parent_locale]})
        end
      end
    end
  end
end
