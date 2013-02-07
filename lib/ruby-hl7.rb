# encoding: UTF-8
#= ruby-hl7.rb
# Ruby HL7 is designed to provide a simple, easy to use library for
# parsing and generating HL7 (2.x) messages.
#
#
# Author:    Mark Guzman  (mailto:segfault@hasno.info)
#
# Copyright: (c) 2006-2009 Mark Guzman
#
# License:   BSD
#
#  $Id$
#
# == License
# see the LICENSE file
#

require 'rubygems'
require 'stringio'
require 'date'

module HL7 # :nodoc:
  VERSION = '1.0.3'
  def self.ParserConfig
    @parser_cfg ||= { :empty_segment_is_error => true }
  end
end

# Encapsulate HL7 specific exceptions
class HL7::Exception < StandardError
end

# Parsing failed
class HL7::ParseError < HL7::Exception
end

# Attempting to use an invalid indice
class HL7::RangeError < HL7::Exception
end

# Attempting to assign invalid data to a field
class HL7::InvalidDataError < HL7::Exception
end

# Ruby Object representation of an hl7 2.x message
# the message object is actually a "smart" collection of hl7 segments
# == Examples
#
# ==== Creating a new HL7 message
#
#  # create a message
#  msg = HL7::Message.new
#
#  # create a MSH segment for our new message
#  msh = HL7::Message::Segment::MSH.new
#  msh.recv_app = "ruby hl7"
#  msh.recv_facility = "my office"
#  msh.processing_id = rand(10000).to_s
#
#  msg << msh # add the MSH segment to the message
#
#  puts msg.to_s # readable version of the message
#
#  puts msg.to_hl7 # hl7 version of the message (as a string)
#
#  puts msg.to_mllp # mllp version of the message (as a string)
#
# ==== Parse an existing HL7 message
#
#  raw_input = open( "my_hl7_msg.txt" ).readlines
#  msg = HL7::Message.new( raw_input )
#
#  puts "message type: %s" % msg[:MSH].message_type
#
#
class HL7::Message
  include Enumerable # we treat an hl7 2.x message as a collection of segments
  attr :element_delim
  attr :item_delim
  attr :segment_delim

  # setup a new hl7 message
  # raw_msg:: is an optional object containing an hl7 message
  #           it can either be a string or an Enumerable object
  def initialize( raw_msg=nil, &blk )
    @segments = []
    @segments_by_name = {}
    @item_delim = "^"
    @element_delim = '|'
    @segment_delim = "\r"

    parse( raw_msg ) if raw_msg

    if block_given?
      blk.call self
    end
  end

  # access a segment of the message
  # index:: can be a Range, Fixnum or anything that
  #         responds to to_sym
  def []( index )
    ret = nil

    if index.kind_of?(Range) || index.kind_of?(Fixnum)
      ret = @segments[ index ]
    elsif (index.respond_to? :to_sym)
      ret = @segments_by_name[ index.to_sym ]
      ret = ret.first if ret && ret.length == 1
    end

    ret
  end

  # modify a segment of the message
  # index:: can be a Range, Fixnum or anything that
  #         responds to to_sym
  # value:: an HL7::Message::Segment object
  def []=( index, value )
    unless ( value && value.kind_of?(HL7::Message::Segment) )
      raise HL7::Exception.new( "attempting to assign something other than an HL7 Segment" )
    end

    if index.kind_of?(Range) || index.kind_of?(Fixnum)
      @segments[ index ] = value
    elsif index.respond_to?(:to_sym)
      (@segments_by_name[ index.to_sym ] ||= []) << value
    else
      raise HL7::Exception.new( "attempting to use an indice that is not a Range, Fixnum or to_sym providing object" )
    end

    value.segment_parent = self
  end

  # return the index of the value if it exists, nil otherwise
  # value:: is expected to be a string
  def index( value )
    return nil unless (value && value.respond_to?(:to_sym))

    segs = @segments_by_name[ value.to_sym ]
    return nil unless segs

    @segments.index( segs.to_a.first )
  end

  # add a segment or array of segments to the message
  # * will force auto set_id sequencing for segments containing set_id's
  def <<( value )
    # do nothing if value is nil
    return unless value

    if value.kind_of? Array
      value.map{|item| append(item)}
    else
      append(value)
    end
  end

  def append( value )
    unless ( value && value.kind_of?(HL7::Message::Segment) )
      raise HL7::Exception.new( "attempting to append something other than an HL7 Segment" )
    end

    value.segment_parent = self unless value.segment_parent
    (@segments ||= []) << value
    name = value.class.to_s.gsub("HL7::Message::Segment::", "").to_sym
    (@segments_by_name[ name ] ||= []) << value
    sequence_segments unless @parsing # let's auto-set the set-id as we go
  end

  class << self
    def parse_batch(batch) # :yields: message
      raise HL7::ParseError, 'badly_formed_batch_message' unless
        batch.hl7_batch?

      batch = clean_batch_for_jruby batch

      raise HL7::ParseError, 'empty_batch_message' unless
        match = /\rMSH/.match(batch)

      match.post_match.split(/\rMSH/).each_with_index do |_msg, index|
        if md = /\rBTS/.match(_msg)
          # TODO: Validate the message count in the BTS segment
          # should == index + 1
          _msg = md.pre_match
        end

        yield 'MSH' + _msg
      end
    end

    # parse a String or Enumerable object into an HL7::Message if possible
    # * returns a new HL7::Message if successful
    def parse( inobj )
      HL7::Message.new do |msg|
        msg.parse( inobj )
      end
    end

    # JRuby seems to change our literal \r characters in sample
    # messages (from here documents) into newlines.  We make a copy
    # here, reverting to carriage returns.  The input is unchanged.
    #
    # This does not occur when posts are received with CR
    # characters, only in sample messages from here documents.  The
    # expensive copy is only incurred when the batch message has a
    # newline character in it.
    def clean_batch_for_jruby(batch)
      batch.gsub("\n", "\r") if batch.include?("\n")
    end
  end

  # parse the provided String or Enumerable object into this message
  def parse( inobj )
    unless inobj.kind_of?(String) || inobj.respond_to?(:each)
      raise HL7::ParseError.new( "object to parse should be string or enumerable" )
    end

    if inobj.kind_of?(String)
        parse_string( inobj )
    elsif inobj.respond_to?(:each)
        parse_enumerable( inobj )
    end
  end

  # yield each segment in the message
  def each # :yields: segment
    return unless @segments
    @segments.each { |s| yield s }
  end

  # return the segment count
  def length
    0 unless @segments
    @segments.length
  end

  # provide a screen-readable version of the message
  def to_s
    @segments.collect { |s| s if s.to_s.length > 0 }.join( "\n" )
  end

  # provide a HL7 spec version of the message
  def to_hl7
    @segments.collect { |s| s if s.to_s.length > 0 }.join( @segment_delim )
  end

  # provide the HL7 spec version of the message wrapped in MLLP
  def to_mllp
    pre_mllp = to_hl7
    "\x0b" + pre_mllp + "\x1c\r"
  end

  # auto-set the set_id fields of any message segments that
  # provide it and have more than one instance in the message
  def sequence_segments(base=nil)
    last = nil
    segs = @segments
    segs = base.children if base

    segs.each do |s|
      if s.kind_of?( last.class ) && s.respond_to?( :set_id )
        last.set_id = 1 unless last.set_id && last.set_id.to_i > 0
        s.set_id = last.set_id.to_i + 1
      end

      if s.respond_to?(:children)
        sequence_segments( s )
      end

      last = s
    end
  end

  private
  # Get the element delimiter from an MSH segment
  def parse_element_delim(str)
    (str && str.kind_of?(String)) ? str.slice(3,1) : "|"
  end

  # Get the item delimiter from an MSH segment
  def parse_item_delim(str)
    (str && str.kind_of?(String)) ? str.slice(4,1) : "^"
  end

  def parse_enumerable( inary )
    #assumes an enumeration of strings....
    inary.each do |oary|
      parse_string( oary.to_s )
    end
  end

  def parse_string( instr )
    post_mllp = instr
    if /\x0b((:?.|\r|\n)+)\x1c\r/.match( instr )
      post_mllp = $1 #strip the mllp bytes
    end

    ary = post_mllp.split( segment_delim, -1 )
    generate_segments( ary )
  end

  def generate_segments( ary )
    raise HL7::ParseError.new( "no array to generate segments" ) unless ary.length > 0

    @parsing = true
    last_seg = nil
    ary.each do |elm|
      if elm.slice(0,3) == "MSH"
        @item_delim = parse_item_delim(elm)
        @element_delim = parse_element_delim(elm)
      end
      last_seg = generate_segment( elm, last_seg ) || last_seg
    end
    @parsing = nil
  end

  def generate_segment( elm, last_seg )
      seg_parts = elm.split( @element_delim, -1 )
      unless seg_parts && (seg_parts.length > 0)
        raise HL7::ParseError.new( "empty segment is an error per configuration setting" ) if HL7.ParserConfig[:empty_segment_is_error] || false
        return nil
      end

      seg_name = seg_parts[0]
      if RUBY_VERSION < "1.9" && HL7::Message::Segment.constants.index(seg_name) # do we have an implementation?
        kls = eval("HL7::Message::Segment::%s" % seg_name)
      elsif RUBY_VERSION >= "1.9" && HL7::Message::Segment.constants.index(seg_name.to_sym)
        kls = eval("HL7::Message::Segment::%s" % seg_name)
      else
        # we don't have an implementation for this segment
        # so lets just preserve the data
        kls = HL7::Message::Segment::Default
      end
      new_seg = kls.new( elm, [@element_delim, @item_delim] )
      new_seg.segment_parent = self

      if last_seg && last_seg.respond_to?(:children) && last_seg.accepts?( seg_name )
        last_seg.children << new_seg
        new_seg.is_child_segment = true
        return last_seg
      end

      @segments << new_seg

      # we want to allow segment lookup by name
      if seg_name && (seg_name.strip.length > 0)
        seg_sym = seg_name.to_sym
        @segments_by_name[ seg_sym ] ||= []
        @segments_by_name[ seg_sym ] << new_seg
      end

      new_seg
  end
end