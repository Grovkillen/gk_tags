# frozen_string_literal: true

module GkTags
  # #tag in formatted text becomes a link to the tag. Only a handle that is a global tag's key or alias is linked;
  # #123 stays core's issue link, a Markdown heading (# and a space) is not a handle, and nothing inside a link, code
  # or pre is touched. The runs of text come from GK Core Stuff's pass (formatting_processors) after core has
  # formatted the text, where Processor is registered as this plugin's text processor (patches.rb); the plugin never
  # reads the finished HTML itself. Without GK Core Stuff no handle is linked.
  module TextLinks
    # Also #ns:value (the value may start with a digit) and #parent/child
    CANDIDATE = %r{(?<=\A|[\s(\[>,;])#(\p{L}[\p{L}\p{N}_.\-]*(?::[\p{L}\p{N}][\p{L}\p{N}_.\-]*(?:/[\p{L}\p{N}][\p{L}\p{N}_.\-]*)*|(?:/\p{L}[\p{L}\p{N}_.\-]*)+)?)}
    # The references looked up in one text at most
    LIMIT = 100

    module_function

    # One run of text (plain, entities decoded) as HTML with its handles as links, or nil when none resolves. found:
    # { reference => tag, or false when it resolves to none }, shared by the runs of one text, so that each
    # reference is looked up once and at most LIMIT of them
    def replace(text, root, found)
      return nil unless text.is_a?(String) && text.include?('#') && text.match?(CANDIDATE)

      refs = text.scan(CANDIDATE).flatten.filter_map { |h| GkTags.parse_ref(h) && written(h) }.uniq
      ask = (refs - found.keys).first([LIMIT - found.size, 0].max)
      ask.each { |h| found[h] = GkTags.resolve(h) || false }
      return nil unless refs.any? { |r| found[r] }

      ERB::Util.html_escape(text).to_str.gsub(CANDIDATE) do |m|
        tag = found[written(::Regexp.last_match(1))]
        tag ? %(<a class="gk-tags-pill #{tag.pill_classes}" href="#{root}/gk_tags/t/#{ERB::Util.url_encode(tag.key)}#{page_query(tag)}" title="#{ERB::Util.html_escape(tag.parent_id ? tag.path_label : tag.label)}">#{m}</a>) : m
      end.html_safe
    end

    # A piece of HTML through GK Core Stuff's pass with only this plugin's links, whatever a project's module says
    # (the scenarios' check); as it came without GK Core Stuff
    def link(html, root = '')
      return html unless GkTags.ready? && defined?(::GkCoreStuff::FormattingProcessors)

      fp = ::GkCoreStuff::FormattingProcessors
      found = {}
      fp.process(html, fp::Context.new(source: html), link: [],
                                                      text: [->(run, _c) { run.in_link? ? nil : replace(run.text, root, found) }])
    end

    # A reference in stored form: lowercase, NFC
    def written(h) = h.to_s.unicode_normalize(:nfc).downcase

    # A tag whose written form is not its key is found by its id on its page (### hierarchy, ### types)
    def page_query(tag) = tag.ref == tag.key ? '' : "?tag_id=#{tag.id}"

    # Links follow the project module gk_tags: only where the module is on for the text's project; a text without
    # a known project is linked as before
    def linked_in?(project) = !project.is_a?(::Project) || project.module_enabled?(:gk_tags)

    # The start of a tag's address: on a page the path's root; where the context asks for full addresses (only_path
    # false: mail, a feed, a PDF) the address as core builds it there, through the view's url helper of this plugin's
    # own route (the mail's host from the settings, or the request's), else from Setting.protocol and Setting.host_name
    # as core's mail does
    def root_for(context)
      root = Redmine::Utils.relative_url_root.to_s
      context.only_path ? root : full_root(context.view) || root
    end

    def full_root(view)
      if view.respond_to?(:gk_tags_tag_page_url)
        url = view.gk_tags_tag_page_url(handle: 'x').to_s
        base = url.delete_suffix('/gk_tags/t/x')
        return base if base != url && base.match?(%r{\Ahttps?://[^/]}i)
      end
      host = ::Setting.host_name.to_s.strip.sub(%r{\Ahttps?://}i, '').chomp('/')
      host.empty? ? nil : "#{::Setting.protocol}://#{host}"
    rescue StandardError
      nil
    end

    # The text processor in GK Core Stuff's formatting_processors: every run of text outside a link, code, pre, a form
    # field, a script and a style, where the project's module is on. Whether a text holds a handle is decided on each
    # run as the reader reads it (entities decoded: &num;tag is #tag), never on the text as written.
    module Processor
      module_function

      def active?(context) = GkTags.ready? && TextLinks.linked_in?(context.project)

      def call(run, context)
        return nil if run.in_link? || !run.text.include?('#')

        root = context.memo(:gk_tags_root) { TextLinks.root_for(context) }
        TextLinks.replace(run.text, root, context.memo(:gk_tags_found) { {} })
      end
    end
  end
end
