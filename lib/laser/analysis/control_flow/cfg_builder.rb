module Laser
  module SexpAnalysis
    module ControlFlow
      # This class builds a control flow graph. The algorithm used is
      # derived from Robert Morgan's "Building an Optimizing Compiler".
      class GraphBuilder
        attr_reader :graph, :enter, :exit, :temporary_counter, :current_block, :sexp
        
        def initialize(sexp)
          @sexp = sexp
          @graph = @enter = @exit = nil
          @temporary_counter = 0
        end
        
        def build
          initialize_graph
          @current_return = @exit
          p current_return.name
          result = value_walk @sexp
          return_uncond_jump_instruct result
          @graph
        end
        
        # Walks the node expecting that the expression's return value will be discarded.
        # Since everything is an expression in Ruby, knowing when to ignore return
        # values is nice.
        def novalue_walk(node)
          case node.type
          when :void_stmt
            # Do nothing.
          when :bodystmt
            result = create_temporary
            # TODO(adgar): RESCUE, ELSE, ENSURE
            body, rescue_body, else_body, ensure_body = node.children
            body_block = create_block
            uncond_instruct body_block
            
            if ensure_body
              with_jumps_redirected(:break => ensure_body[1], :redo => ensure_body[1], :next => ensure_body[1],
                                    :return => ensure_body[1]) do
                start_block body_block
                body_result = walk_body body
              end
              # Natural completion with no uncaught raises leads to ensure block. This
              # same block should be used for exits from raises!
              ensure_block, after = create_blocks 2
              uncond_instruct ensure_block
              walk_body_novalue(ensure_body[1])
              uncond_instruct after
              result
            else
              start_block body_block
              body_result = walk_body body
              copy_instruct(result, body_result)
              result
            end
          when :begin
            novalue_walk node[1]
          when :paren
            node[1].each { |stmt| novalue_walk stmt }
          when :assign
            lhs, rhs = node.children
            case lhs.type
            when :field
              # In 1.9.2, receiver is evaulated first, then the arguments
              receiver = value_walk lhs[1]
              method_name = lhs[3].expanded_identifier
              rhs_val = value_walk rhs
              call_instruct_novalue(receiver, "#{method_name}=".to_sym, rhs_val, :block => false)
            else
              assign_instruct(lhs.binding, rhs)
            end
          when :opassign
            lhs, op, rhs = node.children
            op = op.expanded_identifier[0..-2].to_sym
            if lhs.type == :field
              receiver = value_walk lhs[1]
              method_name = lhs[3].expanded_identifier
              # Receiver is ONLY EVALUATED ONCE
              # (on ruby 1.9.2p136 (2010-12-25 revision 30365) [x86_64-darwin10.6.0])
              current_val = call_instruct(receiver, method_name.to_sym, :block => false)
              if op == :"||"
                false_block, after = create_blocks 2
                cond_instruct(current_val, after, false_block)

                start_block false_block
                rhs_value = value_walk rhs
                call_instruct_novalue(receiver, "#{method_name}=".to_sym, rhs_value, :block => false)
                uncond_instruct after
                
                start_block after
              elsif op == :"&&"
                true_block, after = create_blocks 2
                cond_instruct(current_val, true_block, after)

                start_block true_block
                rhs_value = value_walk rhs
                call_instruct_novalue(receiver, "#{method_name}=".to_sym, rhs_value, :block => false)
                uncond_instruct after
                
                start_block after
              else
                rhs_value = value_walk rhs
                temp_result = call_instruct(current_val, op, rhs_value, :block => false)
                call_instruct_novalue(receiver, "#{method_name}=".to_sym, temp_result, :block => false)
              end
            else
              result = binary_instruct(lhs, op, rhs)
              copy_instruct(lhs.binding, result)
            end
          when :binary
            # If someone makes an overloaded operator that mutates something....
            # we have to run it (maybe), even if we hate them.
            lhs, op, rhs = node.children
            binary_instruct_novalue(lhs, op, rhs)
          when :unary
            op, receiver = node.children
            receiver = value_walk(receiver)
            call_instruct_novalue(receiver, op)
          when :while
            condition, body = node.children
            while_instruct_novalue(condition, body)
          when :while_mod
            condition, body_stmt = node.children
            while_instruct_novalue(condition, [body_stmt])
          when :until
            condition, body = node.children
            until_instruct_novalue(condition, body)
          when :until_mod
            condition, body_stmt = node.children
            until_instruct_novalue(condition, [body_stmt])
          when :if
            if_instruct_novalue(node)
          when :unless
            condition, body, else_block = node.children
            unless_instruct_novalue(condition, body, else_block)
          when :if_mod
            if_instruct_novalue(node, true)
          when :unless_mod
            condition, body = node.children
            unless_instruct_novalue(condition, [body], nil)
          when :case
            after = create_block
            argument, body = node.children
            argument_value = value_walk argument
            
            while body && body.type == :when
              when_opts, when_body, body = body.children
              when_body_block = create_block
              when_opts.each do |opt|
                after_fail = create_block
                condition_result = call_instruct(value_walk(opt), :===, argument_value)
                cond_instruct(condition_result, when_body_block, after_fail)
                start_block after_fail
              end
              all_fail = @current_block

              start_block when_body_block
              walk_body_novalue when_body
              uncond_instruct after
              
              start_block all_fail
            end
            if body.type == :else
              walk_body_novalue body[1]
            end
            uncond_instruct after
          when :return
            return_instruct node
          when :return0
            return0_instruct
          when :break
            break_instruct(node[1])
          when :next
            next_instruct(node[1])
          when :redo
            redo_instruct
          when :var_ref
            if node.binding.nil?
              call_instruct_novalue(node.scope.lookup('self'), node.expanded_identifier)
            end
          when :command
            issue_call_novalue node
          when :command_call
            issue_call_novalue node
          when :method_add_arg
            issue_call_novalue node
          when :method_add_block
            # need: the receiver, the method name, the arguments, and the block body
            method_call = node.method_call
            receiver = if method_call.receiver_node
                       then value_walk method_call.receiver_node
                       else self_instruct(node[2][2].scope)
                       end
            arg_node = method_call.arg_node
            arg_node = arg_node[1] if arg_node && arg_node.type == :arg_paren
            block_arg_bindings = Signature.arg_list_for_arglist(node[2][1][1])
            body_sexp = node[2][2]
            case node[1].type
            when :super
              arg_node = arg_node[1] if arg_node.type == :args_add_block
              call_method_with_block_novalue(
                  receiver, method_call.method_name, arg_node,
                  block_arg_bindings, body_sexp)
            when :zsuper
              call_zsuper_with_block_novalue(node[1], block_arg_bindings, body_sexp)
            else
              call_method_with_block_novalue(
                  receiver, method_call.method_name, arg_node, block_arg_bindings, body_sexp)
            end
          when :super
            args = node[1]
            args = args[1] if args.type == :arg_paren
            _, args, block = args
            generic_super_instruct_novalue(args, block)
          when :zsuper
            # TODO(adgar): blocks in args & style
            invoke_super_with_block_novalue(*compute_zsuper_arguments(node), false)
          when :for
            lhs, receiver, body = node.children
            receiver_value = value_walk receiver
            if Symbol === lhs[0]
              # field or var_ref/const_ref
              case lhs.type
              when :field
                # TODO(adgar): generate calls
              else
                # just get the value
                arg_bindings = [lhs.binding]
                call_method_with_block_novalue(receiver_value, :each, [], arg_bindings, body)
              end
            else
              # TODO(adgar): multiple assign
            end
          when :string_embexpr
            node[1].each { |elt| novalue_walk(elt) }
          when :@CHAR, :@tstring_content, :@int, :@float, :@regexp_end, :symbol,
               :@label, :symbol_literal
            # do nothing
          when :string_literal
            content_nodes = node[1].children
            content_nodes.each do |node|
              novalue_walk node
            end
          when :xstring_literal
            body = build_string_instruct(node[1])
            call_instruct(node.scope.lookup('self'), :`, body)
          when :regexp_literal
            node[1].each { |part| novalue_walk node }
          else
            raise ArgumentError.new("Unknown AST node type #{node.type.inspect}")
          end
        end
        
        # Walks the node with the expectation that the return value will be used.
        def value_walk(node)
          case node.type
          when :bodystmt
            result = create_temporary
            # TODO(adgar): RESCUE, ELSE, ENSURE
            body, rescue_body, else_body, ensure_body = node.children
            body_block = create_block
            uncond_instruct body_block
            
            if ensure_body
              start_block body_block
              with_jumps_redirected(:break => ensure_body[1], :redo => ensure_body[1], :next => ensure_body[1],
                                    :return => ensure_body[1]) do
                start_block body_block
                body_result = walk_body body
              end
              
              ensure_block, after = create_blocks 2
              uncond_instruct ensure_block
              walk_body_novalue(ensure_body[1])
              uncond_instruct after
              result
            else
              start_block body_block
              body_result = walk_body body
              copy_instruct(result, body_result)
              result
            end
          when :begin
            value_walk node[1]
          when :paren
            walk_body node[1]
          when :assign
            lhs, rhs = node.children
            case lhs.type
            when :field
              # In 1.9.2, receiver is evaulated first, then the arguments
              receiver = value_walk lhs[1]
              method_name = lhs[3].expanded_identifier
              rhs_val = value_walk rhs
              call_instruct(receiver, "#{method_name}=".to_sym, rhs_val, :block => false)
            else
              assign_instruct(lhs.binding, rhs)
            end
          when :opassign
            lhs, op, rhs = node.children
            op = op.expanded_identifier[0..-2].to_sym
            if lhs.type == :field
              receiver = value_walk lhs[1]
              method_name = lhs[3].expanded_identifier
              # Receiver is ONLY EVALUATED ONCE
              # (on ruby 1.9.2p136 (2010-12-25 revision 30365) [x86_64-darwin10.6.0])
              current_val = call_instruct(receiver, method_name.to_sym, :block => false)
              if op == :"||"
                result = create_temporary
                true_block, false_block, after = create_blocks 3
                cond_instruct(current_val, true_block, false_block)

                start_block true_block
                copy_instruct result, current_val
                uncond_instruct after

                start_block false_block
                rhs_value = value_walk rhs
                call_instruct_novalue(receiver, "#{method_name}=".to_sym, rhs_value, :block => false)
                copy_instruct result, rhs_value
                uncond_instruct after
                
                start_block after
                result
              elsif op == :"&&"
                result = create_temporary
                true_block, false_block, after = create_blocks 3
                cond_instruct(current_val, true_block, false_block)

                start_block true_block
                rhs_value = value_walk rhs
                call_instruct_novalue(receiver, "#{method_name}=".to_sym, rhs_value, :block => false)
                copy_instruct result, rhs_value
                uncond_instruct after

                start_block false_block
                copy_instruct result, current_val
                uncond_instruct after
                
                start_block after
                result
              else
                rhs_value = value_walk rhs
                temp_result = call_instruct(current_val, op, rhs_value, :block => false)
                call_instruct_novalue(receiver, "#{method_name}=".to_sym, temp_result, :block => false)
                temp_result
              end
            else
              result = binary_instruct(lhs, op, rhs)
              copy_instruct(lhs.binding, result)
              result
            end
          when :binary
            lhs, op, rhs = node.children
            binary_instruct(lhs, op, rhs)
          when :unary
            op, receiver = node.children
            receiver = value_walk(receiver)
            call_instruct(receiver, op)
          when :var_field
            variable_instruct(node)
          when :var_ref
            if node.binding
            then variable_instruct(node)
            else issue_call node
            end
          when :call
            issue_call node
          when :command
            issue_call node
          when :command_call
            issue_call node
          when :method_add_arg
            issue_call node
          when :method_add_block
            # need: the receiver, the method name, the arguments, and the block body
            method_call = node.method_call
            receiver = if method_call.receiver_node
                       then value_walk method_call.receiver_node
                       else self_instruct(node[2][2].scope)
                       end
            arg_node = method_call.arg_node
            arg_node = arg_node[1] if arg_node && arg_node.type == :arg_paren
            case node[1].type
            when :super
              arg_node = arg_node[1] if arg_node.type == :args_add_block
              call_method_with_block(
                  receiver, method_call.method_name, arg_node,
                  Signature.arg_list_for_arglist(node[2][1][1]), node[2][2])
            when :zsuper
              call_zsuper_with_block(node[1], 
                  Signature.arg_list_for_arglist(node[2][1][1]), node[2][2])
            else
              call_method_with_block(
                  receiver, method_call.method_name, arg_node,
                  Signature.arg_list_for_arglist(node[2][1][1]), node[2][2])
            end
          when :super
            args = node[1]
            args = args[1] if args.type == :arg_paren
            _, args, block = args
            generic_super_instruct(args, block)
          when :zsuper
            # TODO(adgar): blocks in args & style
            invoke_super_with_block(*compute_zsuper_arguments(node), false)
          when :for
            lhs, receiver, body = node.children
            receiver_value = value_walk receiver
            if Symbol === lhs[0]
              # field or var_ref/const_ref
              case lhs.type
              when :field
                # call
              else
                # just get the value
                arg_bindings = [lhs.binding]
                call_method_with_block(receiver_value, :each, [], arg_bindings, body)
              end
            else
              # TODO(adgar): multiple assign
            end
          when :while
            condition, body = node.children
            while_instruct(condition, body)
          when :while_mod
            condition, body_stmt = node.children
            while_instruct(condition, [body_stmt])
          when :until
            condition, body = node.children
            until_instruct(condition, body)
          when :until_mod
            condition, body_stmt = node.children
            until_instruct(condition, [body_stmt])
          when :if
            if_instruct(node)
          when :unless
            condition, body, else_block = node.children
            unless_instruct(condition, body, else_block)
          when :if_mod
            if_instruct(node, true)
          when :unless_mod
            condition, body = node.children
            unless_instruct(condition, [body], nil)
          when :case
            after = create_block
            result = create_temporary
            argument, body = node.children
            argument_value = value_walk argument
            
            while body && body.type == :when
              when_opts, when_body, body = body.children
              when_body_block = create_block
              when_opts.each do |opt|
                after_fail = create_block
                condition_result = call_instruct(value_walk(opt), :===, argument_value)
                cond_instruct(condition_result, when_body_block, after_fail)
                start_block after_fail
              end
              all_fail = @current_block

              start_block when_body_block
              when_body_result = walk_body when_body
              copy_instruct(result, when_body_result)
              uncond_instruct after
              
              start_block all_fail
            end
            if body.nil?
              copy_instruct(result, nil)
              uncond_instruct after
            elsif body.type == :else
              else_body_result = walk_body body[1]
              copy_instruct(result, else_body_result)
              uncond_instruct after
            end
              
            start_block after
            result
          when :return
            return_instruct node
            const_instruct(nil)
          when :return0
            return0_instruct
            const_instruct(nil)
          when :break
            break_instruct(node[1])
            const_instruct(nil)
          when :next
            next_instruct(node[1])
            const_instruct(nil)
          when :redo
            redo_instruct
            const_instruct(nil)
          when :void_stmt
            const_instruct(nil)
          when :@CHAR, :@tstring_content, :@int, :@float, :@regexp_end, :symbol,
               :@label, :symbol_literal
            const_instruct(node.constant_value)
          when :string_literal
            content_nodes = node[1].children
            build_string_instruct(content_nodes)
          when :string_embexpr
            final = walk_body node[1]
            call_instruct(final, :to_s)
          when :xstring_literal
            body = build_string_instruct(node[1])
            call_instruct(node.scope.lookup('self'), :`, body)
          when :regexp_literal
            body = build_string_instruct(node[1])
            options = const_instruct(node[2].constant_value)
            receiver = Scope::GlobalScope.lookup('Regexp')
            call_instruct(receiver, :new, body, options)
          else
            raise ArgumentError.new("Unknown AST node type #{node.type.inspect}")
          end
        end
        
       private
        def initialize_graph
          @graph = ControlFlowGraph.new
          @block_counter = 0
          @enter = create_block('Enter')
          @exit = create_block('Exit')
          @temporary_counter = 0
          @current_break = @current_next = @current_redo = @current_return = nil
          p current_return
          start_block @enter
        end
        
        # Redirects break, next, redo, and return to the given Sexp for each
        # target to redirect.
        def with_jumps_redirected(targets={})
          p targets
          p({:break => current_break, :next => current_next, :redo => current_redo, :return => current_return })
          new_targets = targets.merge(targets) do |key, redirect|
            new_block = create_block
            start_block new_block
            walk_body_novalue redirect
            uncond_instruct send("current_#{key}")
            new_block
          end
          p new_targets
          with_jump_targets(new_targets) do
            yield
          end
        end
        
        # Yields with jump targets specified. Since a number of jump targets
        # require temporary specification in a stack-like fashion during CFG construction,
        # I use the call stack to simulate the explicit one suggested by Morgan.
        def with_jump_targets(targets={})
          old_break, old_next, old_redo, old_return =
              @current_break, @current_next, @current_redo, @current_return
          @current_break = targets[:break] if targets.has_key?(:break)
          @current_next = targets[:next] if targets.has_key?(:next)
          @current_redo = targets[:redo] if targets.has_key?(:redo)
          @current_return = targets[:return] if targets.has_key?(:return)
          yield
        ensure
          @current_break, @current_next, @current_redo, @current_return =
              old_break, old_next, old_redo, old_return
        end
        
        # Walks over a series of statements, ignoring the return value of
        # everything except the last statement. Stores the result of the
        # last statement in the result parameter.
        def walk_body(body)
          body[0..-2].each { |elt| novalue_walk(elt) }
          if body.any?
            value_walk(body.last)
          else
            const_instruct(nil)
          end
        end
        
        # Walks the series of statements with no regard for any of their
        # return values.
        def walk_body_novalue(body)
          body.each { |node| novalue_walk node }
        end
        
        # Terminates the current block with a jump to the target block.
        def uncond_instruct(target)
          add_instruction(:jump, target.name)
          @graph.add_edge(@current_block, target)
          start_block target
        end
        
        # TODO(adgar): Cleanup on Aisle 6.

        # Yields with an explicit block being wrapped around the execution of the
        # user's block. The basic block object created is provided as a parameter to the
        # caller's operations which have the possibility of invoking the block.
        def call_with_explicit_block(block_arg_bindings, block_sexp)
          after = create_block
          body_value, body_block = call_block_instruct block_arg_bindings, block_sexp
          result = yield(body_block, after)
          block_funcall_branch_instruct(body_block, after)
          walk_block_body body_block, block_sexp, after
          start_block after
          result
        end

        def call_zsuper_with_block_novalue(node, block_arg_bindings, block_sexp)
          call_with_explicit_block(block_arg_bindings, block_sexp) do |body_block, after|
            invoke_super_with_block_novalue *compute_zsuper_arguments(node), body_block.name
          end
        end

        def call_zsuper_with_block(node, block_arg_bindings, block_sexp)
          call_with_explicit_block(block_arg_bindings, block_sexp) do |body_block, after|
            invoke_super_with_block *compute_zsuper_arguments(node), body_block.name
          end
        end
        
        def call_method_with_block_novalue(receiver, method, args, block_arg_bindings, block_sexp)
          call_with_explicit_block(block_arg_bindings, block_sexp) do |body_block, after|
            generic_call_instruct_novalue receiver, method, args, body_block.name
          end
        end

        def call_method_with_block(receiver, method, args, block_arg_bindings, block_sexp)
          call_with_explicit_block(block_arg_bindings, block_sexp) do |body_block, after|
            generic_call_instruct receiver, method, args, body_block.name
          end
        end
        
        def invoke_super_with_block(args, is_vararg, body_block)
          # TODO(adgar): blocks in args & style
          if is_vararg
          then super_vararg_instruct(args, :block => body_block)
          else super_instruct(*args, :block => body_block)
          end
        end
        
        def invoke_super_with_block_novalue(args, is_vararg, body_block)
          # TODO(adgar): blocks in args & style
          if is_vararg
          then super_vararg_instruct_novalue(args, :block => body_block)
          else super_instruct_novalue(*args, :block => body_block)
          end
        end
        
        # Performs the branches either into the block or around it. Later, this
        # method can provide logic for skipping provably skippable edges.
        def block_funcall_branch_instruct(body_block, after_block)
          @graph.add_edge(@current_block, body_block)
          @graph.add_edge(@current_block, after_block)
        end
        
        # Walks the block with it's new next/etc. boundaries set based on the block's
        # scope
        def walk_block_body(body_block, body, after)
          start_block body_block
          body_result = walk_body body
          add_instruction(:resume, body_result)
          cond_instruct(nil, body_block, after)
        end
        
        # Creates an unconditional branch from the current block, based on the given
        # value, to either the true block or the false block.
        def cond_instruct(val, true_block, false_block)
          add_instruction(:branch, val, true_block.name, false_block.name)
          @graph.add_edge(@current_block, true_block)
          @graph.add_edge(@current_block, false_block)
        end
        
        # Performs a no-arg return.
        def return0_instruct
          add_instruction(:return, nil)
          uncond_instruct @current_return
          start_block create_block
        end
        
        def return_instruct(node)
          args = node[1][1]
          if args[0] == :args_add_star
            # if there's a splat, always return an actual array object of all the arguments.
            result = compute_varargs(args)
          elsif args.size > 1
            # if there's more than 1 argument, but no splats, then we just pack
            # them into an array and return that array.
            arg_temps = args.map { |arg| value_walk arg }
            result = call_instruct(ClassRegistry['Array'].binding, :new)
            arg_temps.each { |arg| call_instruct_novalue(arg_array, :<<, arg) }
          else
            # Otherwise, just 1 simple argument: return it.
            result = value_walk args[0]
          end
          return_uncond_jump_instruct result
        end
        
        def return_uncond_jump_instruct(result)
          add_instruction(:return, result)
          uncond_instruct @current_return
          start_block create_block
          result
        end
        
        attr_reader :current_break, :current_next, :current_redo, :current_return
        
        # TODO(adgar): ARGUMENTS
        def break_instruct(args)
          uncond_instruct @current_break
          start_block create_block
        end
        
        # TODO(adgar): ARGUMENTS
        def next_instruct(args)
          uncond_instruct @current_next
          start_block create_block
        end

        def redo_instruct
          uncond_instruct @current_redo
          start_block create_block
        end

        # Creates a temporary, assigns it a constant value, and returns it.
        def const_instruct(val)
          result = create_temporary
          add_instruction(:assign, result, val)
          result
        end
        
        def self_instruct(scope)
          result = create_temporary
          add_instruction(:assign, result, scope.lookup('self'))
          result
        end
        
        # Copies one register to another.
        def copy_instruct(lhs, rhs)
          add_instruction(:assign, lhs, rhs)
        end
        
        # Computes the RHS and assigns it to the LHS, returning the RHS result.
        def assign_instruct(lhs, rhs)
          result = value_walk rhs
          add_instruction(:assign, lhs, result)
          result
        end

        #TODO(adgar): RAISES HERE!
        def convert_type(value, klass, method)
          result = create_temporary
          if_klass_block, if_not_klass_block, after = create_blocks 3
          
          comparison_result = call_instruct(klass, :===, value)
          cond_instruct(comparison_result, if_klass_block, if_not_klass_block)
          
          start_block if_not_klass_block
          conversion_result = call_instruct(value, method)
          copy_instruct result, conversion_result
          uncond_instruct after
          
          start_block if_klass_block
          copy_instruct(result, value)
          uncond_instruct after
          
          start_block after
          result
        end

        # Creates a block for a method send operation. Requires a binding list
        # and a sexp for the body of the block.
        #
        # args: [Argument]
        # body: Sexp
        # returns: (TemporaryBinding, BasicBlock)
        def call_block_instruct(args, body)
          result = create_temporary
          body_block = create_block
          add_instruction :lambda, result, args, body_block.name
          [result, body_block]
        end
        
        def issue_call(node)
          method_call = node.method_call
          receiver = receiver_instruct node
          generic_call_instruct(receiver,
              method_call.method_name, method_call.arg_node, method_call.arguments.block_arg)
        end
        
        def issue_call_novalue(node)
          method_call = node.method_call
          receiver = receiver_instruct node
          generic_call_instruct_novalue(receiver,
              method_call.method_name, method_call.arg_node, method_call.arguments.block_arg)
        end
        
        def receiver_instruct(node)
          method_call = node.method_call
          if method_call.receiver_node
          then value_walk method_call.receiver_node
          else self_instruct(node.scope)
          end
        end
        
        # Given a receiver, a method, a method_add_arg node, and a block value,
        # issue a call instruction. This will involve computing the arguments,
        # potentially issuing a vararg call (if splats are used). The return
        # value is captured and returned to the caller of this method.
        def generic_call_instruct(receiver, method, args, block)
          args = [] if args.nil?
          if args[0] == :args_add_star
            arg_array = compute_varargs(args)
            call_vararg_instruct(receiver, method, arg_array, :block => block)
          else
            arg_temps = args.map { |arg| value_walk arg }
            call_instruct(receiver, method, *arg_temps, :block => block)
          end
        end
        
        # Given a receiver, a method, a method_add_arg node, and a block value,
        # issue a call instruction. This will involve computing the arguments,
        # potentially issuing a vararg call (if splats are used). The return
        # value is not captured.
        def generic_call_instruct_novalue(receiver, method, args, block)
          args = [] if args.nil?
          if args[0] == :args_add_star
            arg_array = compute_varargs(args)
            call_vararg_instruct_novalue(receiver, method, arg_array, :block => block)
          else
            arg_temps = args.map { |arg| value_walk arg }
            call_instruct_novalue(receiver, method, *arg_temps, :block => block)
          end
        end

        # Given a receiver, a method, a method_add_arg node, and a block value,
        # issue a super instruction. This will involve computing the arguments,
        # potentially issuing a vararg super (if splats are used). The return
        # value is captured and returned to the superer of this method.
        def generic_super_instruct(args, block)
          if args[0] == :args_add_star
            arg_array = compute_varargs(args)
            super_vararg_instruct(arg_array, :block => block)
          else
            arg_temps = args.map { |arg| value_walk arg }
            super_instruct(*arg_temps, :block => block)
          end
        end

        # Given a receiver, a method, a method_add_arg node, and a block value,
        # issue a super instruction. This will involve computing the arguments,
        # potentially issuing a vararg super (if splats are used). The return
        # value is not captured.
        def generic_super_instruct_novalue(args, block)
          if args[0] == :args_add_star
            arg_array = compute_varargs(args)
            super_vararg_instruct_novalue(arg_array, :block => block)
          else
            arg_temps = args.map { |arg| value_walk arg }
            super_instruct_novalue(*arg_temps, :block => block)
          end
        end

        # Computes the arguments to a zsuper call at the given node. Also returns
        # whether the resulting argument expansion is of variable arity.
        # This is different from normal splatting because we are computing based
        # upon the argument list of the method, not a normal arg_ node.
        #
        # returns: (Bindings::GenericBinding | [Bindings::GenericBinding], Boolean)
        def compute_zsuper_arguments(node)
          args_to_walk = node.scope.method.signatures.first.arguments
          is_vararg = args_to_walk.any? { |arg| arg.kind == :rest }
          if is_vararg
            index_of_star = args_to_walk.index { |arg| arg.kind == :rest }
            # splatting vararg call. assholes
            result = call_instruct(ClassRegistry['Array'].binding, :new)
            args_to_walk[0...index_of_star].each do |arg|
              call_instruct_novalue(result, :<<, variable_instruct(arg), :block => false)
            end
            starred = variable_instruct args_to_walk[index_of_star]
            starred_converted = convert_type(starred, ClassRegistry['Array'].binding, :to_a)
            call_instruct_novalue(result, :concat, starred_converted)
            args_to_walk[index_of_star+1 .. -1].each do |arg|
              call_instruct_novalue(result, :<<, variable_instruct(arg), :block => false)
            end
            [result, is_vararg]
          else
            [args_to_walk.map { |arg| variable_instruct arg }, is_vararg]
          end
        end

        # Computes a splatting node (:args_add_star)
        def compute_varargs(args)
          result = create_temporary
          if args[1][0] == :args_add_star || args[1].children.any?
            prefix = if args[1][0] == :args_add_star
                     then compute_varargs(args[1])
                     else prefix = build_array_instruct(args[1].children)
                     end
            call_instruct_novalue(result, :concat, prefix)
          end
          starred = value_walk args[2]
          starred_converted = convert_type(starred, ClassRegistry['Array'].binding, :to_a)
          call_instruct_novalue(result, :concat, starred_converted)
          if args[3..-1].any?
            suffix = build_array_instruct(args[3..-1])
            call_instruct_novalue(result, :concat, suffix)
          end
          result
        end

        # Adds a no-value call instruction (it discards the return value).
        def call_instruct_novalue(receiver, method, *args)
          add_instruction(:call, nil, receiver, method, *args)
        end
        
        # Adds a generic method call instruction.
        def call_instruct(receiver, method, *args)
          result = create_temporary
          add_instruction(:call, result, receiver, method, *args)
          result
        end
        
        # Adds a no-value call instruction (it discards the return value).
        def call_vararg_instruct_novalue(receiver, method, args, block)
          add_instruction(:call_vararg, nil, receiver, method, args, block)
        end
        
        # Adds a generic method call instruction.
        def call_vararg_instruct(receiver, method, args, block)
          result = create_temporary
          add_instruction(:call_vararg, result, receiver, method, args, block)
          result
        end

        # Adds a no-value super instruction (it discards the return value).
        def super_instruct_novalue(*args)
          add_instruction(:super, nil, *args)
        end
        
        # Adds a generic method super instruction.
        def super_instruct(*args)
          result = create_temporary
          add_instruction(:super, result, *args)
          result
        end
        
        # Adds a no-value super instruction (it discards the return value).
        def super_vararg_instruct_novalue(args, block)
          add_instruction(:super_vararg, nil, args, block)
        end
        
        # Adds a generic method super instruction.
        def super_vararg_instruct(args, block)
          result = create_temporary
          add_instruction(:super_vararg, result, args, block)
          result
        end

        # Looks up the value of a variable and assigns it to a new temporary
        def variable_instruct(var_ref)
          result = create_temporary
          var_ref = var_ref.binding unless Bindings::GenericBinding === var_ref
          add_instruction(:assign, result, var_ref)
          result
        end
        
        def binary_instruct_novalue(lhs, op, rhs)
          if op == :or || op == :"||"
            return or_instruct_novalue(lhs, rhs)
          elsif op == :and || op == :"&&"
            return and_instruct_novalue(lhs, rhs)
          end

          lhs_result = value_walk lhs
          rhs_result = value_walk rhs
          call_instruct_novalue(lhs, op, rhs)
        end
        
        def binary_instruct(lhs, op, rhs)
          if op == :or || op == :"||"
            return or_instruct(lhs, rhs)
          elsif op == :and || op == :"&&"
            return and_instruct(lhs, rhs)
          end

          lhs_result = value_walk lhs
          rhs_result = value_walk rhs
          call_instruct(lhs, op, rhs)
        end
        
        # Runs the list of operations in body while the condition is true.
        def while_instruct_novalue(condition, body)
          body_block, after_block, precond_block = create_blocks 3

          with_jump_targets(:break => after_block, :redo => body_block, :next => precond_block) do
            uncond_instruct precond_block
            start_block precond_block
            
            cond_result = value_walk condition
            cond_instruct(cond_result, body_block, after_block)

            start_block body_block
            walk_body_novalue body
            cond_result = value_walk condition
            cond_instruct(cond_result, body_block, after_block)
          end
          
          start_block after_block
        end
        
        # Runs the list of operations in body while the condition is true.
        # Then returns nil.
        def while_instruct(condition, body)
          body_block, after_block, precond_block = create_blocks 3

          with_jump_targets(:break => after_block, :redo => body_block, :next => precond_block) do
            uncond_instruct precond_block
            start_block precond_block
            
            cond_result = value_walk condition
            cond_instruct(cond_result, body_block, after_block)

            start_block body_block
          
            walk_body_novalue body
            cond_result = value_walk condition
            cond_instruct(cond_result, body_block, after_block)
          end
          
          start_block after_block
          const_instruct(nil)
        end
        
        # Runs the list of operations in body until the condition is true.
        def until_instruct_novalue(condition, body)
          body_block, after_block, precond_block = create_blocks 3

          with_jump_targets(:break => after_block, :redo => body_block, :next => precond_block) do
            uncond_instruct precond_block
            start_block precond_block
            
            cond_result = value_walk condition
            cond_instruct(cond_result, after_block, body_block)

            start_block body_block
          
            walk_body_novalue body
            cond_result = value_walk condition
            cond_instruct(cond_result, after_block, body_block)
          end
          
          start_block after_block
        end
        
        # Runs the list of operations in body until the condition is true.
        # Then returns nil.
        def until_instruct(condition, body)
          body_block, after_block, precond_block = create_blocks 3

          with_jump_targets(:break => after_block, :redo => body_block, :next => precond_block) do
            uncond_instruct precond_block
            start_block precond_block
            
            cond_result = value_walk condition
            cond_instruct(cond_result, after_block, body_block)

            start_block body_block
          
            walk_body_novalue body
            cond_result = value_walk condition
            cond_instruct(cond_result, after_block, body_block)
          end
          
          start_block after_block
          const_instruct(nil)
        end
        
        # Performs an OR operation, with short circuiting that must save
        # the result of the operation.
        def or_instruct(lhs, rhs)
          result = create_temporary
          true_block, false_block, after = create_blocks 3

          lhs_result = value_walk lhs
          cond_instruct(lhs_result, true_block, false_block)
          
          start_block(true_block)
          copy_instruct(result, lhs_result)
          uncond_instruct(after)
          
          start_block(false_block)
          rhs_result = value_walk rhs
          copy_instruct(result, rhs_result)
          uncond_instruct(after)
          
          start_block(after)
          result
        end
        
        # Performs an OR operation, with short circuiting, that ignores
        # whatever return value results.
        def or_instruct_novalue(lhs, rhs)
          false_block, after = create_blocks 2

          lhs_result = value_walk lhs
          cond_instruct(lhs_result, after, false_block)
          
          start_block(false_block)
          novalue_walk rhs
          uncond_instruct(after)
          start_block(after)
        end
        
        # Performs an AND operation, with short circuiting, that must save
        # the result of the operation.
        def and_instruct(lhs, rhs)
          result = create_temporary
          true_block, false_block, after = create_blocks 3

          lhs_result = value_walk lhs
          cond_instruct(lhs_result, true_block, false_block)
          
          start_block(true_block)
          rhs_result = value_walk rhs
          copy_instruct(result, rhs_result)
          uncond_instruct(after)
          
          start_block(false_block)
          copy_instruct(result, lhs_result)
          uncond_instruct(after)

          start_block(after)
          result
        end
        
        # Performs an AND operation, with short circuiting, that ignores
        # whatever return value results.
        def and_instruct_novalue(lhs, rhs)
          true_block, after = create_blocks 2

          lhs_result = value_walk lhs
          cond_instruct(lhs_result, true_block, after)

          start_block(true_block)
          novalue_walk rhs
          uncond_instruct(after)
          start_block(after)
        end

        # Performs a value-capturing if instruction, with unlimited else-ifs
        # and a potential else block.
        #
        # condition: Sexp
        # body: [Sexp]
        # else_block: Sexp | NilClass
        def if_instruct(node, is_mod=false)
          result = create_temporary
          after = create_block
          current = node
          next_block = nil
          
          while current
            if current.type == :else
              true_block = next_block
              body, next_block, else_block = current[1], after, nil
            else
              true_block = create_block
              condition, body, else_block = current.children
              next_block = create_block
              
              cond_result = value_walk condition
              cond_instruct(cond_result, true_block, next_block)
            end
            
            start_block true_block
            body = [body] if is_mod
            body_result = walk_body body
            copy_instruct(result, body_result)
            uncond_instruct(after)
            
            start_block next_block
            # check: is there no else at all, and we're about to break out of the loop?
            if current.type != :else && else_block.nil?
              copy_instruct(result, nil)
              uncond_instruct(after)
              start_block after
            end
            current = else_block
          end
          result
        end
        
        # Performs an if instruction that ignores result values, with unlimited else-ifs
        # and a potential else block.
        #
        # condition: Sexp
        # body: [Sexp]
        # else_block: Sexp | NilClass
        def if_instruct_novalue(node, is_mod=false)
          current = node
          after = create_block
          next_block = nil
          
          while current
            if current.type == :else
              true_block = next_block
              body, next_block, else_block = current[1], after, nil
            else
              true_block = create_block
              condition, body, else_block = current.children
              next_block = else_block ? create_block : after
              
              cond_result = value_walk condition
              cond_instruct(cond_result, true_block, next_block)
            end
            
            start_block true_block
            body = [body] if is_mod
            walk_body_novalue body
            uncond_instruct(after)
            
            start_block next_block
            current = else_block
          end
        end
        
        # Performs a value-capturing unless instruction.
        #
        # condition: Sexp
        # body: [Sexp]
        # else_block: Sexp | NilClass
        def unless_instruct(condition, body, else_block)
          result = create_temporary
          after, true_block, next_block = create_blocks 3

          cond_result = value_walk condition
          cond_instruct(cond_result, next_block, true_block)
          
          start_block true_block
          body_result = walk_body body
          copy_instruct(result, body_result)
          uncond_instruct(after)

          start_block next_block
          body_result = if else_block
                        then walk_body else_block[1]
                        else const_instruct nil
                        end
          copy_instruct result, body_result
          uncond_instruct(after)

          start_block after
          result
        end
        
        # Performs an unless instruction, ignoring the potential that its value
        # is saved.
        #
        # condition: Sexp
        # body: [Sexp]
        # else_block: Sexp | NilClass
        def unless_instruct_novalue(condition, body, else_block)
          after, true_block = create_blocks 2
          next_block = else_block ? create_block : after
          
          cond_result = value_walk condition
          cond_instruct(cond_result, next_block, true_block)
          
          start_block true_block
          walk_body_novalue body
          uncond_instruct(after)
          
          if else_block
            start_block next_block
            else_block[1].each { |elt| novalue_walk(elt) }
            uncond_instruct(after)
          end
          
          start_block after
        end
        
        # Takes a set of either :@tstring_content or :string_embexpr nodes
        # and constructs a string out of them. (In other words, this computes
        # the contents of possibly-interpolated strings).
        def build_string_instruct(components)
          temp = const_instruct('')
          components.each do |node|
            as_string = value_walk node
            temp = call_instruct(temp, :concat, as_string)
          end
          temp
        end
        
        # Takes a set of nodes, finds their values, and builds a temporary holding
        # the array containing them.
        def build_array_instruct(components)
          temp = call_instruct(ClassRegistry['Array'].binding, :new)
          components.each do |node|
            call_instruct_novalue(temp, :<<, value_walk(node))
          end
          temp
        end
        
        # Returns the name of the current temporary.
        def current_temporary
          "%t#{@temporary_counter}"
        end

        # Creates a temporary variable with an unused name.
        def create_temporary
          @temporary_counter += 1
          Bindings::TemporaryBinding.new(current_temporary, nil)
        end
        
        # Adds a simple instruction to the current basic block.
        def add_instruction(*args)
          @current_block << args
        end
        
        # Creates the given number of blocks.
        def create_blocks(count)
          (0...count).to_a.map { create_block }
        end

        # Creates a new basic block for flow analysis.
        def create_block(name = 'B' + (@block_counter += 1).to_s)
          BasicBlock.new(name).tap { |block| @graph.add_vertex block }
        end
        
        # Sets the current block to be the given block.
        def start_block(block)
          @current_block = block
        end
      end
    end
  end
end