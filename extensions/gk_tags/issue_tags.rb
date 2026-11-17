# frozen_string_literal: true

module GkTags
  # Tagging issues through the tag field. gk_tag_list is a safe attribute, so the form, bulk edit and REST take it
  # alike. Handles resolve through keys and aliases; an unknown handle becomes a free tag for whoever may create
  # free tags, else the issue is not saved. A change is a line in the same journal as the issue's other changes.
  # Taggings are never deleted (removed_at).
  module IssuePatch
    JOURNAL_KEY = 'gk_tags_tags'

    def self.prepended(base)
      base.safe_attributes 'gk_tag_list', if: ->(issue, user) { GkTags::Access.tag?(issue, user) }
      base.validate :gk_tags_validate_list
      base.before_save :gk_tags_journal_detail
      base.after_save :gk_tags_apply
    end

    # The issue's tags now: [tag], a merged one shown as the tag it was merged into.
    # Named gk_tags_current_tags, not gk_tags, which is the column's own method below
    def gk_tags_current_tags = GkTags::Tagging.tags_of(self)

    # Each tag as it is written (ns:key, a path where the type repeats keys, else the key)
    def gk_tag_list = gk_tags_current_tags.map(&:ref).join(' ')

    # Text from REST and scenarios, a list from the form's chooser
    def gk_tag_list=(value)
      @gk_tags_input = GkTags.list_text(value)
    end

    private

    # [GkTags::Tagging::Want] for what was written, or nil when the field was not given
    def gk_tags_wanted
      return nil if @gk_tags_input.nil?

      @gk_tags_wanted ||= GkTags::Tagging.read(@gk_tags_input)
    end

    # The handles, and the types' rules (exclusive, allowed_on, required_for) for the key issue
    def gk_tags_validate_list
      return unless (w = gk_tags_wanted)

      GkTags::Tagging.check(self, w, ::User.current, key: 'issue').each { |m| errors.add(:base, m) }
    end

    def gk_tags_keys_wanted = gk_tags_wanted.select { |w| %i[ok new].include?(w.status) }.map { |w| GkTags::Tagging.ref_of(w) }.uniq.sort

    # The change as a line in the issue's journal (the update's own journal, so it reads with the other changes)
    def gk_tags_journal_detail
      return if gk_tags_wanted.nil? || new_record? || current_journal.nil?

      before = gk_tags_current_tags.map(&:ref).sort
      after = gk_tags_keys_wanted
      return if before == after

      current_journal.details << ::JournalDetail.new(property: 'attr', prop_key: JOURNAL_KEY, old_value: before.join(' '), value: after.join(' '))
    end

    def gk_tags_apply
      return if gk_tags_wanted.nil?

      GkTags::IssueTagging.apply(self, ::User.current, gk_tags_wanted)
      @gk_tags_input = nil
      @gk_tags_wanted = nil
      @gk_tags_preloaded = nil
    end
  end

  # Setting an issue's tags to exactly the given ones. Used by the issue's save.
  module IssueTagging
    module_function

    def apply(issue, user, wanted) = GkTags::Tagging.apply(issue, user, wanted)
    def read(text) = GkTags::Tagging.read(text)
  end

  # The filters Tagg, Märkt and I fokus and the column Taggar on IssueQuery (### queries, ### marks, ### focus; core
  # patch, documented). Plain core filters: with gk_queries they also take part in OR groups and blocks.
  module IssueQueryPatch
    def initialize_available_filters
      super
      return unless GkTags.ready?

      # Each tag as it is written, with its path when it has a parent
      add_available_filter 'gk_tags', type: :list_optional, name: ::I18n.t(:label_gk_tags_tags),
                                      values: -> { ::GkTagsTag.global.usable.sorted.includes(:type, :parent).map { |t| [t.parent_id ? "##{t.ref} (#{t.path_label})" : "##{t.ref}", t.id.to_s] } }
      # Märkt and I fokus only while their declared functions are on
      if GkTags.feature?('tags.marks')
        add_available_filter 'gk_marked', type: :list, name: ::I18n.t(:label_gk_tags_marked),
                                          values: -> { [[::I18n.t(:label_gk_tags_by_me), 'me'], [::I18n.t(:label_gk_tags_by_anyone), 'any']] }
      end
      return unless GkTags.feature?('tags.focus')

      add_available_filter 'gk_focus', type: :list, name: ::I18n.t(:label_gk_tags_in_focus),
                                       values: -> { [[::I18n.t(:label_gk_tags_by_me), 'me'], [::I18n.t(:label_gk_tags_by_anyone), 'any']] }
    end

    def available_columns
      cols = super
      return cols if !GkTags.ready? || cols.any? { |c| c.name == :gk_tags }

      cols << ::QueryColumn.new(:gk_tags, caption: :label_gk_tags_tags)
    end

    # With the column Taggar, the tags of every issue of the page are read in one go (Tagging.preload), for the list,
    # CSV and PDF alike
    def issues(options = {})
      list = super
      GkTags::Tagging.preload(list) if GkTags.ready? && has_column?(:gk_tags)
      list
    end

    def sql_for_gk_tags_field(_field, operator, value)
      base = "SELECT tg.taggable_id FROM gk_tags_taggings tg JOIN gk_tags_tags t ON t.id = tg.tag_id " \
             "WHERE tg.taggable_type = 'Issue' AND tg.removed_at IS NULL AND t.kind = 'tag'"
      case operator
      when '*' then "#{queried_table_name}.id IN (#{base})"
      when '!*' then "#{queried_table_name}.id NOT IN (#{base})"
      else
        # With the descendants whose type inherits (Hierarchy.search_ids), for is and is not
        ids = GkTags::Hierarchy.search_ids(::GkTagsTag.where(id: Array(value).map(&:to_i)).to_a)
        ids = [0] if ids.empty?
        sub = "#{base} AND tg.tag_id IN (#{ids.map(&:to_i).join(',')})"
        operator == '!' ? "#{queried_table_name}.id NOT IN (#{sub})" : "#{queried_table_name}.id IN (#{sub})"
      end
    end

    # Marked by me (my own marks, on the issue or on one of its notes), or by anyone (my own and every shared mark;
    # someone else's personal mark is never counted)
    def sql_for_gk_marked_field(_field, operator, value)
      me = ::User.current.id.to_i
      who = Array(value).include?('any') ? "(t.owner_id = #{me} OR t.shared = TRUE)" : "t.owner_id = #{me}"
      sub = "SELECT CASE WHEN tg.taggable_type = 'Issue' THEN tg.taggable_id ELSE j.journalized_id END " \
            "FROM gk_tags_taggings tg JOIN gk_tags_tags t ON t.id = tg.tag_id " \
            "LEFT JOIN #{::Journal.table_name} j ON tg.taggable_type = 'Journal' AND j.id = tg.taggable_id " \
            "WHERE tg.removed_at IS NULL AND t.kind = 'mark' AND #{who}"
      operator == '!' ? "#{queried_table_name}.id NOT IN (#{sub})" : "#{queried_table_name}.id IN (#{sub})"
    end

    # In focus: mine, or anyone's whose current focus the viewer sees, herself included
    def sql_for_gk_focus_field(_field, operator, value)
      ids = Array(value).include?('any') ? GkTags::FocusSharing.visible_owner_ids(::User.current) : [::User.current.id]
      who = "t.owner_id IN (#{(ids.map(&:to_i) + [0]).uniq.join(',')})"
      sub = "SELECT tg.taggable_id FROM gk_tags_taggings tg JOIN gk_tags_tags t ON t.id = tg.tag_id " \
            "WHERE tg.taggable_type = 'Issue' AND tg.removed_at IS NULL AND t.kind = 'focus' AND #{who}"
      operator == '!' ? "#{queried_table_name}.id NOT IN (#{sub})" : "#{queried_table_name}.id IN (#{sub})"
    end
  end

  # The column's value: the tags as text, "#a #b" (CSV, PDF)
  module IssueColumnValue
    def gk_tags = gk_tags_current_tags.map { |t| "##{t.ref}" }.join(' ')
  end

  # The column in the issue list (core patch on QueriesHelper#column_value, documented): each tag as its pill in two
  # links, the list with the tag and the tag's page, without a count on a single issue
  module ColumnPills
    def column_value(column, item, value)
      return super unless column.name == :gk_tags && item.is_a?(::Issue)

      safe_join(item.gk_tags_current_tags.map { |t| gk_tags_pill(t) }, ' ')
    end
  end

  # The tag line in the issue's history, mail, PDF and Atom: core_stuff's register journal_detail (property attr,
  # prop_key IssuePatch::JOURNAL_KEY), so every other detail stays core's. Drawn by the one that asks core's
  # show_detail, as before: line is bound to it.
  module HistoryLine
    def self.call(detail, view, no_html, options) = instance_method(:line).bind_call(view, detail, no_html, options)

    def self.register!
      return nil unless GkTags.gui? # the line stays core's own without GK GUI Stuff (gate.rb)

      unless defined?(::GkCoreStuff::JournalDetails::PluginDsl)
        ::Rails.logger.warn("[gk_tags] gk_core_stuff is missing, although it is required: the tag line in an issue's history is core's own")
        return
      end

      ::Redmine::Plugin.find(:gk_tags).journal_detail property: 'attr', prop_key: GkTags::IssuePatch::JOURNAL_KEY, renderer: self
    end

    # Only the change: "lades till" and "togs bort", each tag as its pill in the simplest form, dimmed like the history
    # around it and leading to the issue list with the tag; a tag taken away struck through. A tag no longer there is
    # quiet text with the tooltip that says so, struck through too when taken away; a merged one is the tag it was
    # merged into, its old name in the tooltip.
    # Mail (also its html part, drawn with full addresses), PDF and Atom get the same words as text.
    def line(detail, no_html = false, options = {})
      before = detail.old_value.to_s.split
      after = detail.value.to_s.split
      parts = [[:text_gk_tags_history_added, after - before, false], [:text_gk_tags_history_removed, before - after, true]].reject { |p| p[1].empty? }
      label = l(:label_gk_tags_tags)
      if no_html || !GkTags::HistoryLine.pills?(self, options)
        text = parts.map { |key, refs, _| "#{l(key)} #{refs.map { |r| "##{r}" }.join(' ')}" }.join('; ').presence || '-'
        return no_html ? "#{label}: #{text}" : safe_join([content_tag('strong', label), ': ', text])
      end

      shown = parts.map { |key, refs, struck| safe_join([l(key), ': ', safe_join(refs.map { |r| GkTags::HistoryLine.pill(self, r, struck) }, ' ')]) }
      safe_join([content_tag('strong', label), ' ', shown.any? ? safe_join(shown, '; ') : '-'])
    end

    # Pills only on a page: not in a mail (full addresses), not in a feed, and only where the helpers are
    def self.pills?(view, options)
      return false if options.is_a?(Hash) && options[:only_path] == false
      return false if view.respond_to?(:formats) && Array(view.formats).include?(:atom)

      view.respond_to?(:gk_tags_pill)
    end

    def self.pill(view, ref, struck)
      tag, merged = GkTags.resolve_kept(ref)
      unless tag
        gone = view.content_tag(:span, "##{ref}", class: 'gk-tags-muted', title: ::I18n.t(:text_gk_tags_history_gone))
        return struck ? view.content_tag(:del, gone) : gone
      end

      title = merged ? ::I18n.t(:text_gk_tags_history_merged, old: "##{ref}", new: "##{tag.ref}") : nil
      view.gk_tags_pill(tag, quiet: true, struck: struck, title: title)
    end
  end
end
