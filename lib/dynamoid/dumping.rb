# frozen_string_literal: true

module Dynamoid
  module Dumping
    def self.dump_attributes(attributes, attributes_options)
      {}.tap do |h|
        attributes.each do |attribute, value|
          h[attribute] = dump_field(value, attributes_options[attribute])
        end
      end
    end

    def self.dump_field(value, options)
      return nil if value.nil?

      dumper = field_dumper(options)

      if dumper.nil?
        raise ArgumentError, "Unknown type #{options[:type]}"
      end

      dumper.process(value)
    end

    def self.field_dumper(options)
      dumper_class = case options[:type]
                     when :string     then StringDumper
                     when :integer    then IntegerDumper
                     when :number     then NumberDumper
                     when :set        then SetDumper
                     when :array      then ArrayDumper
                     when :datetime   then DateTimeDumper
                     when :date       then DateDumper
                     when :serialized then SerializedDumper
                     when :raw        then RawDumper
                     when :boolean    then BooleanDumper
                     when Class       then CustomTypeDumper
                     end

      if dumper_class.present?
        dumper_class.new(options)
      end
    end

    class Base
      def initialize(options)
        @options = options
      end

      def process(value)
        value
      end
    end

    # string -> string
    class StringDumper < Base
    end

    # integer -> number
    class IntegerDumper < Base
    end

    # number -> number
    class NumberDumper < Base
    end

    # set -> set
    class SetDumper < Base
      ALLOWED_TYPES = [:string, :integer, :number, :date, :datetime, :serialized]

      def process(set)
        if @options.key?(:of)
          process_typed_collection(set)
        else
          set
        end
      end

      private

      def process_typed_collection(set)
        if allowed_type?
          dumper = Dumping.field_dumper(element_options)
          result = set.map { |el| dumper.process(el) }

          if element_type == :string
            result.reject!(&:empty?)
          end

          result.to_set
        else
          raise ArgumentError, "Set element type #{element_type} isn't supported"
        end
      end

      def allowed_type?
        ALLOWED_TYPES.include?(element_type) || element_type.is_a?(Class)
      end

      def element_type
        unless @options[:of].is_a?(Hash)
          @options[:of]
        else
          @options[:of].keys.first
        end
      end

      def element_options
        unless @options[:of].is_a?(Hash)
          { type: element_type }
        else
          @options[:of][element_type].dup.tap do |options|
            options[:type] = element_type
          end
        end
      end
    end

    # array -> array
    class ArrayDumper < Base
    end

    # datetime -> integer/string
    class DateTimeDumper < Base
      def process(value)
        !value.nil? ? format_datetime(value, @options) : nil
      end

      private

      def format_datetime(value, options)
        use_string_format = if options[:store_as_string].nil?
                              Dynamoid.config.store_datetime_as_string
                            else
                              options[:store_as_string]
                            end

        if use_string_format
          value_in_time_zone = Dynamoid::DynamodbTimeZone.in_time_zone(value)
          value_in_time_zone.iso8601
        else
          unless value.respond_to?(:to_i) && value.respond_to?(:nsec)
            value = value.to_time
          end
          BigDecimal(format('%d.%09d', value.to_i, value.nsec))
        end
      end
    end

    # date -> integer/string
    class DateDumper < Base
      def process(value)
        !value.nil? ? format_date(value, @options) : nil
      end

      private

      def format_date(value, options)
        use_string_format = if options[:store_as_string].nil?
                              Dynamoid.config.store_date_as_string
                            else
                              options[:store_as_string]
                            end

        if use_string_format
          value.to_date.iso8601
        else
          (value.to_date - Dynamoid::Persistence::UNIX_EPOCH_DATE).to_i
        end
      end
    end

    # any standard Ruby object -> self
    class RawDumper < Base
      def process(value)
        deep_sanitize(value)
      end

      private

      def deep_sanitize(el)
        case el
        when Hash
          sanitize_hash(el).transform_values { |v| deep_sanitize(v) }
        when Array
          sanitize_array(el).map { |v| deep_sanitize(v) }
        else
          el
        end
      end

      def sanitize_hash(h)
        h.transform_values { |v| invalid_value?(v) ? nil : v }
      end

      def sanitize_array(a)
        a.map { |v| invalid_value?(v) ? nil : v }
      end

      def invalid_value?(v)
        (v.is_a?(Set) || v.is_a?(String)) && v.empty?
      end
    end

    # object -> string
    class SerializedDumper < Base
      def process(value)
        @options[:serializer] ? @options[:serializer].dump(value) : value.to_yaml
      end
    end

    # True/False -> True/False/string
    class BooleanDumper < Base
      def process(value)
        unless value.nil?
          store_as_boolean = if @options[:store_as_native_boolean].nil?
                               Dynamoid.config.store_boolean_as_native
                             else
                               @options[:store_as_native_boolean]
                             end
          if store_as_boolean
            !!value
          else
            value.to_s[0] # => "f" or "t"
          end
        end
      end
    end

    # any object -> string
    class CustomTypeDumper < Base
      def process(value)
        field_class = @options[:type]

        if value.respond_to?(:dynamoid_dump)
          value.dynamoid_dump
        elsif field_class.respond_to?(:dynamoid_dump)
          field_class.dynamoid_dump(value)
        else
          raise ArgumentError, "Neither #{field_class} nor #{value} supports serialization for Dynamoid."
        end
      end
    end
  end
end
