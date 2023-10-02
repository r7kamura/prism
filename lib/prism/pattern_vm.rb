# frozen_string_literal: true

module Prism
  class PatternVM
    class Compiler < BasicVisitor
      # Raised when the query given to a pattern is either invalid Ruby syntax or
      # is using syntax that we don't yet support.
      class CompilationError < StandardError
        def initialize(repr)
          super(<<~ERROR)
            prism was unable to compile the pattern you provided into a usable
            expression. It failed on to understand the node represented by:
  
            #{repr}
  
            Note that not all syntax supported by Ruby's pattern matching syntax
            is also supported by prism's patterns. If you're using some syntax
            that you believe should be supported, please open an issue on
            GitHub at https://github.com/ruby/prism/issues/new.
          ERROR
        end
      end
  
      class Label
        attr_reader :jumps, :splits

        def initialize
          @jumps = []
          @splits = []
        end

        def push_jump(pc)
          jumps << pc
        end

        def push_split(pc, type)
          splits << [pc, type]
        end
      end

      attr_reader :vm, :checktype, :passing, :failing
  
      def initialize(vm)
        @vm = vm
        @checktype = true
        @passing = nil
        @failing = nil
      end

      # in foo | bar
      def visit_alternation_pattern_node(node)
        # First, find all of the clauses that are held by alternation pattern
        # nodes. This will let us do further optimizations if there are more
        # than 2.
        clauses = [node.left, node.right]
        while clauses.first.is_a?(AlternationPatternNode)
          clause = clauses.shift
          clauses.unshift(clause.left, clause.right)
        end

        # Next, we're going to check on the kinds of patterns that we're trying
        # to compile. If it's possible to take advantage of checking the type
        # only once, then we will do that.
        groups =
          clauses.group_by do |clause|
            constant =
              case clause.type
              when :array_pattern_node, :find_pattern_node, :hash_pattern_node
                clause.constant
              when :constant_read_node, :constant_path_node
                clause
              end

            if constant
              parts = []
              while constant.is_a?(ConstantPathNode)
                parts.unshift(constant.child.name)
                constant = constant.parent
              end
              parts.unshift(constant&.name)
            else
              :ungrouped
            end
          end

        # If we have more than one group, we can do a special optimization where
        # we check the type once and then jump to the correct clause.
        if !groups.key?(:ungrouped) && groups.length > 1
          # Next, transform the keys from constant paths to prism types so that
          # we can use the .type method to switch effectively.
          groups.transform_keys! do |path|
            if ((path.length == 1) || (path.length == 2 && path[0] == :Prism)) && Prism.const_defined?(path.last, false)
              Prism.const_get(path.last).type
            else
              path
            end
          end

          # If we found a node type for every group, then we will perform our
          # optimization.
          if groups.keys.none? { |key| key.is_a?(Array) }
            labels = groups.transform_values { vm.label }
            vm.splittype(labels, failing)

            groups.each do |type, clauses|
              vm.pushlabel(labels[type])

              parent_failing = failing
              parent_checktype = checktype
              @checktype = false

              last_index = clauses.length - 1
              clauses.each_with_index do |clause, index|
                @failing = vm.label if index != last_index

                case clause.type
                when :constant_path_node, :constant_read_node
                else
                  visit(clause)
                end

                vm.jump(passing)
                vm.pushlabel(@failing) if index != last_index
              end

              @failing = parent_failing
              @checktype = parent_checktype
            end

            return
          end
        else
          parent_failing = failing
          @failing = vm.label

          visit(node.left)
          vm.jump(passing)

          vm.pushlabel(@failing)
          @failing = parent_failing
          visit(node.right)

          vm.jump(passing)
        end
      end

      # in [foo, bar, baz]
      def visit_array_pattern_node(node)
        compile_error(node) if node.constant || !node.rest.nil? || node.posts.any?
  
        vm.checktype(Array, failing) if checktype
        vm.checklength(node.requireds.length, failing)
  
        parent_checktype = checktype
        @checktype = true

        node.requireds.each_with_index do |required, index|
          vm.pushindex(index)
          visit(required)
          vm.pop
        end
  
        @checktype = parent_checktype
        vm.jump(passing)
      end
  
      # name: Symbol
      def visit_assoc_node(node)
        if node.key.is_a?(Prism::SymbolNode)
          vm.pushfield(node.key.value.to_sym)
          visit(node.value)
        else
          compile_error(node)
        end
      end
  
      # in Prism::ConstantReadNode
      def visit_constant_path_node(node)
        parent = node.parent
  
        if parent.is_a?(ConstantReadNode) && parent.slice == "Prism"
          visit(node.child)
        else
          compile_error(node)
        end
      end
  
      # in ConstantReadNode
      # in String
      def visit_constant_read_node(node)
        value = node.slice
  
        if Prism.const_defined?(value, false)
          vm.checktype(Prism.const_get(value), failing)
        elsif Object.const_defined?(value, false)
          vm.checktype(Object.const_get(value), failing)
        else
          compile_error(node)
        end
      end
  
      # in InstanceVariableReadNode[name: Symbol]
      # in { name: Symbol }
      def visit_hash_pattern_node(node)
        constant = nil
        if node.constant
          constant = node_constant(node.constant)
          visit(node.constant) if checktype
        end

        parent_checktype = checktype
        node.assocs.each do |assoc|
          @checktype = true

          if assoc.is_a?(AssocNode)
            key = assoc.key.value.to_sym

            field = constant.field(key)
            if field
              case field[:type]
              when :node_list
                if assoc.value.is_a?(ArrayPatternNode)
                  @checktype = false
                  visit(assoc)
                  vm.pop
                else
                  compile_error(assoc.value)
                end
              else
                visit(assoc)
                vm.pop
              end
            else
              compile_error(assoc.key)
            end
          else
            compile_error(assoc)
          end
        end

        @checktype = parent_checktype
        vm.jump(passing)
      end
  
      # foo in bar
      def visit_match_predicate_node(node)
        @passing = vm.label
        @failing = vm.label

        visit(node.pattern)

        vm.pushlabel(@failing)
        vm.fail

        vm.pushlabel(@passing)
        @passing = nil
        @failing = nil

        vm.reify!
      end

      # in nil
      def visit_nil_node(node)
        vm.checkobject(nil, failing)
      end

      # in /abc/
      def visit_regular_expression_node(node)
        vm.checkobject(Regexp.new(node.content, node.closing[1..]), failing)
      end

      # in "foo"
      def visit_string_node(node)
        vm.checkobject(node.unescaped, failing)
      end

      # in :foo
      def visit_symbol_node(node)
        vm.checkobject(node.value.to_sym, failing)
      end

      private
  
      def compile_error(node)
        raise CompilationError, node.inspect
      end

      def node_constant(node)
        parts = []
        while node.is_a?(ConstantPathNode)
          parts.unshift(node.child.name)
          node = node.parent
        end
        parts.unshift(node&.name || :Object)

        case parts.length
        when 1
          if Prism.const_defined?(parts[0], false)
            Prism.const_get(parts[0])
          else
            compile_error(node)
          end
        when 2
          if parts[0] == :Prism && Prism.const_defined?(parts[1], false)
            Prism.const_get(parts[1])
          else
            compile_error(node)
          end
        when 3
          if parts[0] == :Object && parts[1] == :Pattern && Prism.const_defined?(parts[2], false)
            Prism.const_get(parts[2])
          else
            compile_error(node)
          end
        else
          compile_error(node)
        end
      end
    end

    attr_reader :insns, :labels, :pattern

    def initialize(pattern)
      @insns = []
      @labels = []
      @pattern = pattern
    end

    def or(other)
      PatternVM.new("#{pattern} | #{other.pattern}")
    end
    alias | or

    def compile
      Prism.parse("nil in #{pattern}").value.statements.body.first.accept(Compiler.new(self))
    end

    def compile_jump(label)
      index = insns.index(label)

      case insns[index + 1]
      when :jump
        compile_jump(insns[index + 2])
      else
        label
      end
    end

    def reify!
      # First pass is to eliminate jump->jump transitions.
      pc = 0
      max_pc = insns.length

      while pc < max_pc
        case (insn = insns[pc])
        when :fail, :pop
          pc += 1
        when :jump
          # insns[pc + 1] is the direct jump label
          insns[pc + 1]
          pc += 2
        when :pushfield, :pushindex
          pc += 2
        when :checklength, :checkobject, :checktype
          # insns[pc + 1] is the failing label
          pc += 3
        when :splittype
          # insns[pc + 1] is a hash of labels, insns[pc + 2] is the failing label
          dispatch = insns[pc + 1]
          dispatch.each do |type, old_label|
            new_label = compile_jump(old_label)
            if old_label != new_label
              old_label.splits.delete([pc + 1, type])
              new_label.splits.push([pc + 1, type])
              dispatch[type] = new_label
            end
          end

          pc += 3
        else
          pc += 1
        end
      end

      # First, we need to find all of the PCs in the list of instructions and
      # track where they are to find their current PCs.
      pc = 0
      max_pc = insns.length

      pcs = {}
      while pc < max_pc
        case (insn = insns[pc])
        when :fail, :pop
          pc += 1
        when :jump, :pushfield, :pushindex
          pc += 2
        when :checklength, :checkobject, :checktype, :splittype
          pc += 3
        else
          if insn.is_a?(Compiler::Label)
            (pcs[pc] ||= []) << insn
            pc += 1
          else
            raise "Unknown instruction: #{insn.inspect}"
          end
        end
      end

      # Next, we need to find their new PCs by accounting for them being removed
      # from the list of instructions.
      pcs.transform_keys!.with_index do |key, index|
        key - index
      end

      # Next, set up the new list of labels to point to the correct PCs.
      pcs = pcs.each_with_object({}) do |(pc, labels), result|
        labels.each do |label|
          result[label] = pc
        end
      end

      # Next, we need to go back and patch the instructions where we should be
      # jumping to labels to point to the correct PC.
      labels.each do |label|
        label.jumps.each do |pc|
          insns[pc] = pcs[label]
        end

        label.splits.each do |(pc, type)|
          insns[pc][type] = pcs[label]
        end
      end

      # Finally, we can remove all of the labels from the list of instructions.
      insns.reject! { |insn| insn.is_a?(Compiler::Label) }
    end

    def disasm
      output = +""
      pc = 0

      while pc < insns.length
        case (insn = insns[pc])
        when :checklength
          output << "%04d %-12s %d, %04d\n" % [pc, insn, insns[pc + 1], insns[pc + 2]]
          pc += 3
        when :checkobject
          output << "%04d %-12s %s, %04d\n" % [pc, insn, insns[pc + 1].inspect, insns[pc + 2]]
          pc += 3
        when :checktype
          output << "%04d %-12s %s, %04d\n" % [pc, insn, insns[pc + 1], insns[pc + 2]]
          pc += 3
        when :fail
          output << "%04d %-12s\n" % [pc, insn]
          pc += 1
        when :jump
          output << "%04d %-12s %04d\n" % [pc, insn, insns[pc + 1]]
          pc += 2
        when :pushfield
          output << "%04d %-12s %s\n" % [pc, insn, insns[pc + 1]]
          pc += 2
        when :pushindex
          output << "%04d %-12s %d\n" % [pc, insn, insns[pc + 1]]
          pc += 2
        when :pop
          output << "%04d %-12s\n" % [pc, insn]
          pc += 1
        when :splittype
          output << "%04d %-12s %s, %04d\n" % [pc, insn, insns[pc + 1].inspect, insns[pc + 2]]
          pc += 3
        else
          raise "Unknown instruction: #{insn.inspect}"
        end
      end

      output
    end

    def run(node)
      stack = [node]

      pc = 0
      max_pc = insns.length

      while pc < max_pc
        case insns[pc]
        when :checklength
          if stack[-1].length == insns[pc + 1]
            pc += 3
          else
            pc = insns[pc + 2]
          end
        when :checkobject
          if insns[pc + 1] === stack[-1]
            pc += 2
          else
            pc = insns[pc + 2]
          end
        when :checktype
          if stack[-1].is_a?(insns[pc + 1])
            pc += 3
          else
            pc = insns[pc + 2]
          end
        when :fail
          return false
        when :jump
          pc = insns[pc + 1]
        when :pushfield
          stack.push(stack[-1].public_send(insns[pc + 1]))
          pc += 2
        when :pushindex
          stack.push(stack[-1][insns[pc + 1]])
          pc += 2
        when :pop
          stack.pop
          pc += 1
        when :splittype
          pc = insns[pc + 1].fetch(stack[-1].type, insns[pc + 2])
        else
          raise "Unknown instruction: #{insns[pc].inspect}"
        end
      end

      true
    end

    def checklength(length, label)
      insns.push(:checklength, length, label)
      label.push_jump(insns.length - 1)
    end

    def checkobject(object, label)
      insns.push(:checkobject, object, label)
      label.push_jump(insns.length - 1)
    end

    def checktype(type, label)
      insns.push(:checktype, type, label)
      label.push_jump(insns.length - 1)
    end

    def fail
      insns.push(:fail)
    end

    def jump(label)
      insns.push(:jump, label)
      label.push_jump(insns.length - 1)
    end

    def label
      new_label = Compiler::Label.new
      labels << new_label
      new_label
    end

    def pop
      insns.push(:pop)
    end

    def pushfield(name)
      insns.push(:pushfield, name)
    end

    def pushindex(index)
      insns.push(:pushindex, index)
    end

    def pushlabel(label)
      insns.push(label)
    end

    def splittype(labels, label)
      insns.push(:splittype, labels, label)
      labels.each { |type, type_label| type_label.push_split(insns.length - 2, type) }
      label.push_jump(insns.length - 1)
    end
  end
end