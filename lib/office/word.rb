require 'office/package'
require 'office/constants'
require 'office/errors'
require 'office/logger'

module Office
  class WordDocument < Package
    attr_accessor :main_doc

    def initialize(filename)
      super(filename)

      main_doc_part = get_relationship_target(WORD_MAIN_DOCUMENT_TYPE)
      raise PackageError.new("Word document package '#{@filename}' has no main document part") if main_doc_part.nil?
      @main_doc = MainDocument.new(self, main_doc_part)
    end

    def self.blank_document(options={})
      base_document = options.delete(:base_document)
      base_document ||= File.join(File.dirname(__FILE__), 'content', 'blank.docx')
      doc = WordDocument.new(base_document)
      doc.filename = nil
      doc
    end

    def self.from_data(data)
      file = Tempfile.new('OfficeWordDocument')
      file.binmode
      file.write(data)
      file.close
      begin
        doc = WordDocument.new(file.path)
        doc.filename = nil
        return doc
      ensure
        file.delete
      end
    end

    def add_heading(text)
      p = @main_doc.add_paragraph
      p.add_style("Heading1")
      p.add_text_run(text)
      p
    end

    def add_sub_heading(text)
      p = @main_doc.add_paragraph
      p.add_style("Heading2")
      p.add_text_run(text)
      p
    end

    def add_paragraph(text, options={})
      p = @main_doc.add_paragraph
      style = options.delete(:style)
      if style
        p.add_style(style)
      end
      p.add_text_run(text)
      p
    end

    def add_image(image, options={}) # image must be an Magick::Image or ImageList
      p = @main_doc.add_paragraph
      style = options.delete(:style)
      if style
        p.add_style(style)
      end
      p.add_run_with_fragment(create_image_run_fragment(image))
      p
    end

    # keys of hash are column headings, each value an array of column data
    # Available options:
    #   :table_style - Table style to use (defaults to LightGrid)
    #   :column_widths - Array of column widths in twips (1 inch = 1440 twips)
    #   :column_styles - Array of paragraph styles to use per column
    #   :table_properties - An Office::TableProperties object (overrides other options)
    #   :skip_header - Don't output the header if set to true
    def add_table(hash, options={})
      @main_doc.add_table(create_table_fragment(hash, options))
    end

    def plain_text
      @main_doc.plain_text
    end

    # The type of 'replacement' determines what replaces the source text:
    #   Image  - an image (Magick::Image or Magick::ImageList)
    #   Hash   - a table, keys being column headings, and each value an array of column data
    #   Array  - a sequence of these replacement types all of which will be inserted
    #   String - simple text replacement
    def replace_all(source_text, replacement)
      case
      # For simple cases we just replace runs to try and keep formatting/layout of source
      when replacement.is_a?(String)
        @main_doc.replace_all_with_text(source_text, replacement)
      when (replacement.is_a?(Magick::Image) or replacement.is_a?(Magick::ImageList))
        runs = @main_doc.replace_all_with_empty_runs(source_text)
        runs.each { |r| r.replace_with_run_fragment(create_image_run_fragment(replacement)) }
      else
        runs = @main_doc.replace_all_with_empty_runs(source_text)
        runs.each { |r| r.replace_with_body_fragments(create_body_fragments(replacement)) }
      end
    end

    def create_body_fragments(item, options={})
      case
      when (item.is_a?(Magick::Image) or item.is_a?(Magick::ImageList))
        [ "<w:p>#{create_image_run_fragment(item)}</w:p>" ]
      when item.is_a?(Hash)
        [ create_table_fragment(item, options) ]
      when item.is_a?(Array)
        create_multiple_fragments(item)
      else
        [ create_paragraph_fragment(item.nil? ? "" : item.to_s, options) ]
      end
    end

    def create_image_run_fragment(image)
      prefix = ["", @main_doc.part.path_components, "media", "image"].flatten.join('/')
      identifier = unused_part_identifier(prefix)
      extension = "#{image.format}".downcase

      part = add_part("#{prefix}#{identifier}.#{extension}", StringIO.new(image.to_blob), image.mime_type)
      relationship_id = @main_doc.part.add_relationship(part, IMAGE_RELATIONSHIP_TYPE)

      Run.create_image_fragment(identifier, image.columns, image.rows, relationship_id)
    end

    # column_widths option, if supplied, is an array of measurements in twips (1 inch = 1440 twips)
    def create_table_fragment(hash, options={})
      c_count = hash.size
      return "" if c_count == 0

      table_properties = options.delete(:table_properties)
      if table_properties
        table_style = table_properties.table_style
        column_widths = table_properties.column_widths
        column_styles = table_properties.column_styles
      else
        table_style = options.delete(:table_style)
        column_widths = options.delete(:column_widths)
        column_styles = options.delete(:column_styles)
        table_properties = TableProperties.new(table_style, column_widths, column_styles)
      end

      skip_header = options.delete(:skip_header)
      fragment = "<w:tbl>#{table_properties}"

      if column_widths
        fragment << "<w:tblGrid>"
        column_widths.each do |column_width|
          fragment << "<w:gridCol w:w=\"#{column_width}\"/>"
        end
        fragment << "</w:tblGrid>"
      end

      unless skip_header
        fragment <<  "<w:tr>"
        hash.keys.each do |header|
          encoded_header = Nokogiri::XML::Document.new.encode_special_chars(header.to_s)
          fragment << "<w:tc><w:p><w:r><w:t>#{encoded_header}</w:t></w:r></w:p></w:tc>"
        end
        fragment << "</w:tr>"
      end

      r_count = hash.values.inject(0) { |max, value| [max, value.is_a?(Array) ? value.length : (value.nil? ? 0 : 1)].max }
      0.upto(r_count - 1).each do |i|
        fragment << "<w:tr>"
        hash.values.each_with_index do |v, j|
          table_cell = create_table_cell_fragment(v, i,
            :width => column_widths ? column_widths[j] : nil,
            :style => column_styles ? column_styles[j] : nil)
          fragment << table_cell
        end
        fragment << "</w:tr>"
      end

      fragment << "</w:tbl>"
      fragment
    end

    def create_table_cell_fragment(values, index, options={})
      item = case
      when (!values.is_a?(Array))
        index != 0 || values.nil? ? "" : values
      when index < values.length
        values[index]
      else
        ""
      end

      width = options.delete(:width)
      xml = create_body_fragments(item, options).join
      # Word validation rules seem to require a w:p immediately before a /w:tc
      xml << "<w:p/>" unless xml.end_with?("<w:p/>") or xml.end_with?("</w:p>")
      fragment = "<w:tc>"
      if width
        fragment << "<w:tcPr><w:tcW w:type=\"dxa\" w:w=\"#{width}\"/></w:tcPr>"
      end
      fragment << xml
      fragment << "</w:tc>"
      fragment
    end

    def create_multiple_fragments(array)
      array.map { |item| create_body_fragments(item) }.flatten
    end

    def create_paragraph_fragment(text, options={})
      style = options.delete(:style)
      fragment = "<w:p>"
      if style
        fragment << "<w:pPr><w:pStyle w:val=\"#{style}\"/></w:pPr>"
      end
      fragment << "<w:r><w:t>#{Nokogiri::XML::Document.new.encode_special_chars(text)}</w:t></w:r></w:p>"
      fragment
    end

    def debug_dump
      super
      @main_doc.debug_dump
      #Logger.debug_dump_xml("Word Main Document", @main_doc.part.xml)
    end
  end

  class MainDocument
    attr_accessor :part
    attr_accessor :body_node
    attr_accessor :paragraphs

    def initialize(word_doc, part)
      @parent = word_doc
      @part = part
      parse_xml
    end

    def parse_xml
      xml_doc = @part.xml
      @body_node = xml_doc.at_xpath("/w:document/w:body")
      raise PackageError.new("Word document '#{@filename}' is missing main document body") if body_node.nil?

      @paragraphs = []
      @body_node.xpath(".//w:p").each { |p| @paragraphs << Paragraph.new(p, self) }
    end

    def add_paragraph
      p_node = @body_node.add_child(@body_node.document.create_element("p"))
      @paragraphs << Paragraph.new(p_node, self)
      @paragraphs.last
    end

    def paragraph_inserted_after(existing, additional)
      p_index = @paragraphs.index(existing)
      raise ArgumentError.new("Cannot find paragraph after which new one was inserted") if p_index.nil?

      @paragraphs.insert(p_index + 1, additional)
    end

    def add_table(xml_fragment)
      table_node = @body_node.add_child(xml_fragment)
      table_node.xpath(".//w:p").each { |p| @paragraphs << Paragraph.new(p, self) }
    end

    def plain_text
      text = ""
      @paragraphs.each do |p|
        p.runs.each { |r| text << r.text unless r.text.nil? }
        text << "\n"
      end
      text
    end

    def replace_all_with_text(source_text, replacement_text)
      @paragraphs.each { |p| p.replace_all_with_text(source_text, replacement_text) }
    end

    def replace_all_with_empty_runs(source_text)
      @paragraphs.collect { |p| p.replace_all_with_empty_runs(source_text) }.flatten
    end

    def debug_dump
      p_count = 0
      r_count = 0
      t_chars = 0
      @paragraphs.each do |p|
        p_count += 1
        p.runs.each do |r|
          r_count += 1
          t_chars += r.text_length
        end
      end
      Logger.debug_dump "Main Document Stats"
      Logger.debug_dump "  paragraphs  : #{p_count}"
      Logger.debug_dump "  runs        : #{r_count}"
      Logger.debug_dump "  text length : #{t_chars}"
      Logger.debug_dump ""

      Logger.debug_dump "Main Document Plain Text"
      Logger.debug_dump ">>>"
      Logger.debug_dump plain_text
      Logger.debug_dump "<<<"
      Logger.debug_dump ""
    end
  end

  class Paragraph
    attr_accessor :node
    attr_accessor :runs
    attr_accessor :document

    def initialize(p_node, parent)
      @node = p_node
      @document = parent
      @runs = []
      p_node.xpath("w:r").each { |r| @runs << Run.new(r, self) }
    end

    # TODO Wrap styles up in a class
    def add_style(style)
      pPr_node = @node.add_child(@node.document.create_element("pPr"))
      pStyle_node = pPr_node.add_child(@node.document.create_element("pStyle"))
      pStyle_node["w:val"] = style
      # TODO return style object
    end

    def add_text_run(text)
      r_node = @node.add_child(@node.document.create_element("r"))
      populate_r_node(r_node, text)

      r = Run.new(r_node, self)
      @runs << r
      r
    end

    def populate_r_node(r_node, text)
      t_node = r_node.add_child(@node.document.create_element("t"))
      t_node["xml:space"] = "preserve"
      t_node.content = text
    end

    def add_run_with_fragment(fragment)
      r = Run.new(@node.add_child(fragment), self)
      @runs << r
      r
    end

    def replace_all_with_text(source_text, replacement_text)
      return if source_text.nil? or source_text.empty?
      replacement_text = "" if replacement_text.nil?

      text = @runs.inject("") { |t, run| t + (run.text || "") }
      until (i = text.index(source_text, i.nil? ? 0 : i)).nil?
        replace_in_runs(i, source_text.length, replacement_text)
        text = replace_in_text(text, i, source_text.length, replacement_text)
        i += replacement_text.length
      end
    end

    def replace_all_with_empty_runs(source_text)
      return [] if source_text.nil? or source_text.empty?

      empty_runs = []
      text = @runs.inject("") { |t, run| t + (run.text || "") }
      until (i = text.index(source_text, i.nil? ? 0 : i)).nil?
        empty_runs << replace_with_empty_run(i, source_text.length)
        text = replace_in_text(text, i, source_text.length, "")
      end
      empty_runs
    end

    def replace_with_empty_run(index, length)
      replaced = replace_in_runs(index, length, "")
      first_run = replaced[0]
      index_in_run = replaced[1]

      r_node = @node.document.create_element("r")
      run = Run.new(r_node, self)
      case
      when index_in_run == 0
        # Insert empty run before first_run
        first_run.node.add_previous_sibling(r_node)
        @runs.insert(@runs.index(first_run), run)
      when index_in_run == first_run.text.length
        # Insert empty run after first_run
        first_run.node.add_next_sibling(r_node)
        @runs.insert(@runs.index(first_run) + 1, run)
      else
        # Split first_run and insert inside
        preceding_r_node = @node.add_child(@node.document.create_element("r"))
        populate_r_node(preceding_r_node, first_run.text[0..index_in_run - 1])
        first_run.text = first_run.text[index_in_run..-1]

        first_run.node.add_previous_sibling(preceding_r_node)
        @runs.insert(@runs.index(first_run), Run.new(preceding_r_node, self))

        first_run.node.add_previous_sibling(r_node)
        @runs.insert(@runs.index(first_run), run)
      end
      run
    end

    def replace_in_runs(index, length, replacement)
      total_length = 0
      ends = @runs.map { |r| total_length += r.text_length }
      first_index = ends.index { |e| e > index }

      first_run = @runs[first_index]
      index_in_run = index - (first_index == 0 ? 0 : ends[first_index - 1])
      if ends[first_index] >= index + length
        first_run.text = replace_in_text(first_run.text, index_in_run, length, replacement)
      else
        length_in_run = first_run.text.length - index_in_run
        first_run.text = replace_in_text(first_run.text, index_in_run, length_in_run, replacement[0,length_in_run])

        last_index = ends.index { |e| e >= index + length }
        remaining_text = length - length_in_run - clear_runs((first_index + 1), (last_index - 1))

        last_run = last_index.nil? ? @runs.last : @runs[last_index]
        last_run.text = replace_in_text(last_run.text, 0, remaining_text, replacement[length_in_run..-1])
      end
      [ first_run, index_in_run ]
    end

    def replace_in_text(original, index, length, replacement)
      return original if length == 0
      result = index == 0 ? "" : original[0, index]
      result += replacement unless replacement.nil?
      result += original[(index + length)..-1] unless index + length == original.length
      result
    end

    def clear_runs(first, last)
      return 0 unless first <= last
      chars_cleared = 0
      @runs[first..last].each do |r|
        chars_cleared += r.text_length
        r.clear_text
      end
      chars_cleared
    end

    def split_after_run(run)
      r_index = @runs.index(run)
      raise ArgumentError.new("Cannot split paragraph on run that is not in paragraph") if r_index.nil?

      next_node = @node.add_next_sibling("<w:p></w:p>")
      next_p = Paragraph.new(next_node, @document)
      @document.paragraph_inserted_after(self, next_p)

      if r_index + 1 < @runs.length
        next_p.runs = @runs.slice!(r_index + 1..-1)
        next_p.runs.each do |r|
          next_node << r.node
          r.paragraph = next_p
        end
      end
    end

    def remove_run(run)
      r_index = @runs.index(run)
      raise ArgumentError.new("Cannot remove run from paragraph to which it does not below") if r_index.nil?

      run.node.remove
      runs.delete_at(r_index)
    end
  end

  class Run
    attr_accessor :node
    attr_accessor :text_range
    attr_accessor :paragraph

    def initialize(r_node, parent_p)
      @node = r_node
      @paragraph = parent_p
      read_text_range
    end

    def replace_with_run_fragment(fragment)
      new_node = @node.add_next_sibling(fragment)
      @node.remove
      @node = new_node
      read_text_range
    end

    def replace_with_body_fragments(fragments)
      @paragraph.split_after_run(self) unless @node.next_sibling.nil?
      @paragraph.remove_run(self)

      fragments.reverse.each do |xml|
        @paragraph.node.add_next_sibling(xml)
        @paragraph.node.next_sibling.xpath(".//w:p").each do |p_node|
          p = Paragraph.new(node, @paragraph.document)
          @paragraph.document.paragraph_inserted_after(@paragraph, p)
        end
      end
    end

    def read_text_range
      t_node = @node.at_xpath("w:t")
      @text_range = t_node.nil? ? nil : TextRange.new(t_node)
    end

    def text
      @text_range.nil? ? nil : @text_range.text
    end

    def text=(text)
      if text.nil?
        @text_range.node.remove unless @text_range.nil?
        @text_range = nil
      elsif @text_range.nil?
        t_node = Nokogiri::XML::Node.new("w:t", @node.document)
        t_node.content = text
        @node.add_child(t_node)
        @text_range = TextRange.new(t_node)
      else
        @text_range.text = text
      end
    end

    def text_length
      @text_range.nil? || @text_range.text.nil? ? 0 : @text_range.text.length
    end

    def clear_text
      @text_range.text = "" unless @text_range.nil?
    end

    def self.create_image_fragment(image_identifier, pixel_width, pixel_height, image_relationship_id)
      fragment = IO.read(File.join(File.dirname(__FILE__), 'content', 'image_fragment.xml'))
      fragment.gsub!("IMAGE_RELATIONSHIP_ID_PLACEHOLDER", image_relationship_id)
      fragment.gsub!("IDENTIFIER_PLACEHOLDER", image_identifier.to_s)
      fragment.gsub!("EXTENT_WIDTH_PLACEHOLDER", (pixel_height * 6000).to_s)
      fragment.gsub!("EXTENT_LENGTH_PLACEHOLDER", (pixel_width * 6000).to_s)
      fragment
    end
  end

  class TableProperties
    attr_accessor :table_style
    attr_accessor :column_widths
    attr_accessor :column_styles

    def initialize(t_style, c_widths, c_styles)
      @table_style = t_style || 'LightGrid'
      @column_widths = c_widths
      @column_styles = c_styles
    end

    # TODO If the 'LightGrid' style is not present in the original Word doc (it is with our blank) then the style is ignored:
    def to_s
      fragment = "<w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/>"
      fragment << "<w:tblLayout w:type=\"fixed\"/>" if @column_widths
      fragment << "<w:tblStyle w:val=\"#{@table_style}\"/>"
      fragment << "<w:tblStyleRowBandSize w:val=\"1\"/>"
      fragment << "<w:tblStyleColBandSize w:val=\"1\"/>"
      fragment << "<w:tblLook w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/>"
      fragment << "</w:tblPr>"
    end
  end

  class TextRange
    attr_accessor :node

    def initialize(t_node)
      @node = t_node
    end

    def text
      @node.text
    end

    def text=(text)
      if text.nil? or text.empty?
        @node.remove_attribute("space")
      else
        @node["xml:space"] = "preserve"
      end
      @node.content = text
    end
  end
end