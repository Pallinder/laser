module Wool
  module SexpAnalysis
    # The ProtocolRegistry module handles negotiating instantiated protocols at
    # compile-time, such as the automatically-generated protocols created by a
    # class creation (as each class has a corresponding protocol, though some
    # distinct classes may have equivalent protocols).
    module ProtocolRegistry
      extend ModuleExtensions
      cattr_accessor_with_default :protocols, []
      cattr_accessor_with_default :class_protocols, {}

      def self.add_protocol(proto)
        self.protocols << proto
      end
      
      def self.register_class_protocol(class_protocol)
        add_protocol class_protocol
        self.class_protocols[class_protocol.class.path] = class_protocol
      end

      def self.[](class_name)
        return query(:class_path => class_name.gsub(/^::/, ''))
      end

      def self.query(query={})
        if query[:class_path]
          return [self.class_protocols[query[:class_path]]]
        end
      end
    end
  end
end