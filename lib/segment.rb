# Ruby Object representation of an hl7 2.x message segment
# The segments can be setup to provide aliases to specific fields with
# optional validation code that is run when the field is modified
# The segment field data is also accessible via the e<number> method.
#
# == Defining a New Segment
#  class HL7::Message::Segment::NK1 < HL7::Message::Segment
#    wieght 100 # segments are sorted ascendingly
#    add_field :something_you_want       # assumes :idx=>1
#    add_field :something_else, :idx=>6  # :idx=>6 and field count=6
#    add_field :something_more           # :idx=>7
#    add_field :block_example do |value|
#       raise HL7::InvalidDataError.new
#                                  unless value.to_i < 100 && value.to_i > 10
#      return value
#    end
#    # this block will be executed when seg.block_example= is called
#    # and when seg.block_example is called
#
class HL7::Message::Segment
  extend HL7::Message::SegmentListStorage

  attr :segment_parent, true
  attr :element_delim
  attr :item_delim
  attr :segment_weight

  # setup a new HL7::Message::Segment
  # raw_segment:: is an optional String or Array which will be used as the
  #               segment's field data
  # delims:: an optional array of delimiters, where
  #               delims[0] = element delimiter
  #               delims[1] = item delimiter
  def initialize(raw_segment="", delims=[], &blk)
    @segments_by_name = {}
    @field_total = 0
    @is_child = false

    setup_delimiters delims

    @elements = elements_from_segment(raw_segment)

    if block_given?
      callctx = eval( "self", blk.binding )
      def callctx.__seg__(val=nil)
        @__seg_val__ ||= val
      end
      callctx.__seg__(self)
      # TODO: find out if this pollutes the calling namespace permanently...

      to_do = <<-END
      def method_missing( sym, *args, &blk )
        __seg__.send( sym, args, blk )
      end
      END

      eval( to_do, blk.binding )
      yield self
      eval( "class << self; remove_method :method_missing;end", blk.binding )
    end
  end

  # Breaks the raw segment into elements
  # raw_segment:: is an optional String or Array which will be used as the
  #               segment's field data
  def elements_from_segment(raw_segment)
    if (raw_segment.kind_of? Array)
      elements = raw_segment
    else
      elements = HL7::MessageParser.split_by_delimiter( raw_segment,
                                                        @element_delim )
      if raw_segment == ""
        elements[0] = self.class.to_s.split( "::" ).last
        elements << ""
      end
    end
    elements
  end

  def to_info
    "%s: empty segment >> %s" % [ self.class.to_s, @elements.inspect ]
  end

  # output the HL7 spec version of the segment
  def to_s
    @elements.join( @element_delim )
  end

  # at the segment level there is no difference between to_s and to_hl7
  alias :to_hl7 :to_s

  # handle the e<number> field accessor
  # and any aliases that didn't get added to the system automatically
  def method_missing( sym, *args, &blk )
    base_str = sym.to_s.gsub( "=", "" )
    base_sym = base_str.to_sym

    if self.class.fields.include?( base_sym )
      # base_sym is ok, let's move on
    elsif /e([0-9]+)/.match( base_str )
      # base_sym should actually be $1, since we're going by
      # element id number
      base_sym = $1.to_i
    else
      super
    end

    if sym.to_s.include?( "=" )
      write_field( base_sym, args )
    else

      if args.length > 0
        write_field( base_sym, args.flatten.select { |arg| arg } )
      else
        read_field( base_sym )
      end

    end
  end

  # sort-compare two Segments, 0 indicates equality
  def <=>( other )
    return nil unless other.kind_of?(HL7::Message::Segment)

    # per Comparable docs: http://www.ruby-doc.org/core/classes/Comparable.html
    diff = self.weight - other.weight
    return -1 if diff > 0
    return 1 if diff < 0
    return 0
  end

  # get the defined sort-weight of this segment class
  # an alias for self.weight
  def weight
    self.class.weight
  end

  # return true if the segment has a parent
  def is_child_segment?
    (@is_child_segment ||= false)
  end

  # indicate whether or not the segment has a parent
  def is_child_segment=(val)
    @is_child_segment = val
  end

  # get the length of the segment (number of fields it contains)
  def length
    0 unless @elements
    @elements.length
  end

  def has_children?
    self.respond_to?(:children)
  end

  private
  def self.singleton #:nodoc:
    class << self; self end
  end

  def setup_delimiters(delims)
    delims = [ delims ].flatten

    @element_delim = ( delims.length>0 ) ? delims[0] : "|"
    @item_delim = ( delims.length>1 ) ? delims[1] : "^"
  end

  # DSL element to define a segment's sort weight
  # returns the segment's current weight by default
  # segments are sorted ascending
  def self.weight(new_weight=nil)
    if new_weight
      singleton.module_eval do
        @my_weight = new_weight
      end
    end

    singleton.module_eval do
      return 999 unless @my_weight
      @my_weight
    end
  end

  # define a field alias
  # * name is the alias itself (required)
  # * options is a hash of parameters
  #   * :id is the field number to reference (optional, auto-increments from 1
  #      by default)
  #   * :blk is a validation proc (optional, overrides the second argument)
  # * blk is an optional validation/convertion proc which MUST take a parameter
  #   and always return a value for the field (it will be used on read/write
  #   calls)
  def self.add_field( name, options={}, &blk )
    options = { :idx =>-1, :blk =>blk}.merge!( options )
    name ||= :id
    namesym = name.to_sym
    @field_cnt ||= 1
    if options[:idx] == -1
      options[:idx] = @field_cnt # provide default auto-incrementing
    end
    @field_cnt = options[:idx].to_i + 1

    singleton.module_eval do
      @fields ||= {}
      @fields[ namesym ] = options
    end

    self.class_eval <<-END
      def #{name}(val=nil)
        unless val
          read_field( :#{namesym} )
        else
          write_field( :#{namesym}, val )
          val # this matches existing n= method functionality
        end
      end

      def #{name}=(value)
        write_field( :#{namesym}, value )
      end
    END
  end

  def self.fields #:nodoc:
    singleton.module_eval do
      (@fields ||= [])
    end
  end

  def self.convert_to_ts(value) #:nodoc:
    value.respond_to?(:to_hl7) ? value.to_hl7 : value
  end

  def field_info( name ) #:nodoc:
    field_blk = nil
    idx = name # assume we've gotten a fixnum
    unless name.kind_of?( Fixnum )
      fld_info = self.class.fields[ name ]
      idx = fld_info[:idx].to_i
      field_blk = fld_info[:blk]
    end

    [ idx, field_blk ]
  end

  def read_field( name ) #:nodoc:
    idx, field_blk = field_info( name )
    return nil unless idx
    return nil if (idx >= @elements.length)

    ret = @elements[ idx ]
    ret = ret.first if (ret.kind_of?(Array) && ret.length == 1)
    ret = field_blk.call( ret ) if field_blk
    ret
  end

  def write_field( name, value ) #:nodoc:
    idx, field_blk = field_info( name )
    return nil unless idx

    if (idx >= @elements.length)
      # make some space for the incoming field, missing items are assumed to
      # be empty, so this is valid per the spec -mg
      missing = ("," * (idx-@elements.length)).split(',',-1)
      @elements += missing
    end

    value = value.first if (value && value.kind_of?(Array) && value.length == 1)
    value = field_blk.call( value ) if field_blk
    @elements[ idx ] = value.to_s
  end

  @elements = []

end


# Provide a catch-all information preserving segment
# * nb: aliases are not provided BUT you can use the numeric element accessor
#
#  seg = HL7::Message::Segment::Default.new
#  seg.e0 = "NK1"
#  seg.e1 = "SOMETHING ELSE"
#  seg.e2 = "KIN HERE"
#
class HL7::Message::Segment::Default < HL7::Message::Segment
  def initialize(raw_segment="", delims=[])
    segs = [] if (raw_segment == "")
    segs ||= raw_segment
    super( segs, delims )
  end
end

# load our segments
Dir["#{File.dirname(__FILE__)}/segments/*.rb"].each { |ext| load ext }
