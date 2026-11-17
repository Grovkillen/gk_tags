# frozen_string_literal: true

module GkTagsHelper
  # A tag as gui_stuff's pill in two links: the whole pill, the tag as written in the tag field (ns:key, or the
  # path where the type repeats keys) and the count, leads to the issue list with the tag; the arrow last leads to the
  # tag's page. In its type's category, its marking, or the muted role without type; the type's icon first, only to
  # read, when the tag's own type has one (an untyped tag has none). split: false on the tag's own page, where the pill
  # is one link to the list. quiet: the simplest form for an issue's history, one link to the list without the icon,
  # the arrow and the count, dimmed like the text around it; struck: a tag taken away; title: the link's tooltip
  def gk_tags_pill(tag, count: nil, split: true, quiet: false, struck: false, title: nil)
    ref = "##{tag.ref}"
    split = false if quiet
    icon = quiet ? nil : tag.type&.icon.presence
    gk_gui_stuff_pill(ref, role: tag.pill_role, type_icon: icon, type_label: icon && tag.type.name, href: gk_tags_issues_path(tag),
                           href_title: title || l(:text_gk_tags_pill_issues, tag: ref), part_href: split ? gk_tags_page_path(tag) : nil,
                           part_title: split ? l(:text_gk_tags_pill_page) : nil, count: quiet ? nil : count, quiet: quiet, struck: struck)
  end

  # The issue list with the tag, every status
  def gk_tags_issues_path(tag) = issues_path(set_filter: 1, f: %w[gk_tags status_id], op: { gk_tags: '=', status_id: '*' }, v: { gk_tags: [tag.id.to_s] })

  # The box Taggar in the sidebar of another plugin's list (people's organizations and persons), from the list's ids
  # before paging (its own scope, so only what the reader may see). A click adds the tag to the list's parameter tag;
  # a click on a chosen tag takes it away again. Nothing while the box or the objects' tags are off.
  def gk_tags_sidebar_box(taggable_type, ids_sql)
    entry = GkTags::Taggables.all.values.find { |e| e.class_name == taggable_type }
    return ''.html_safe unless ids_sql && GkTags::Sidebar.on? && GkTags::Taggables.on?(entry)

    counts = GkTags::Sidebar.counts(taggable_type, ids_sql)
    return ''.html_safe if counts.empty?

    chosen = Array(params[:tag]).map(&:to_i)
    link = lambda do |tag|
      wanted = chosen.include?(tag.id) ? chosen - [tag.id] : chosen + [tag.id]
      url_for(request.query_parameters.merge('tag' => wanted.map(&:to_s), 'page' => nil))
    end
    render partial: 'gk_tags_sidebar/box', locals: { groups: GkTags::Sidebar.groups(counts), top: GkTags::Sidebar.top, limit: GkTags::Sidebar.limit, chosen: chosen, link: link }
  end

  # A tag's page: by the key, and by the id where the written form is not the key
  def gk_tags_page_path(tag) = tag.ref == tag.key ? gk_tags_tag_page_path(handle: tag.key) : gk_tags_tag_page_path(handle: tag.key, tag_id: tag.id)

  # A type's icon as gk_icons draws it (core's, the environment's own or a pack's); core's sprite without icons
  def gk_tags_type_icon(type, size: 14)
    return ''.html_safe if type&.icon.blank?

    respond_to?(:gk_icon) ? gk_icon(type.icon, nil, size: size) : sprite_icon(type.icon.to_s, nil, size: size)
  end

  def gk_tags_category_class(category) = category ? "gk-tags-cat-#{category}" : 'gk-tags-pill-none'

  # A type as a small badge in its category, for lists
  def gk_tags_type_badge(type)
    return ''.html_safe unless type

    content_tag(:span, safe_join([gk_tags_type_icon(type), type.name].reject(&:blank?), ' '), class: "gk-tags-type #{gk_tags_category_class(type.category)}",
                                                                                            title: type.description.presence)
  end

  # A type's rules in short, for the list of types
  def gk_tags_type_rules(type)
    names = ->(keys) { keys.map { |k| GkTags::Taggables.find(k)&.label_text || k }.join(', ') }
    out = []
    out << l(:label_gk_tags_rule_exclusive) if type.exclusive
    out << l(:label_gk_tags_rule_allowed_on, objects: names.call(type.allowed_on_list)) if type.allowed_on_list.any?
    out << l(:label_gk_tags_rule_required_for, objects: names.call(type.required_for_list)) if type.required_for_list.any?
    out << l(:label_gk_tags_rule_no_inherit) unless type.inherit_parents
    out << l(:label_gk_tags_rule_repeat_keys) if type.repeat_keys
    out.join('; ')
  end

  # The types to choose for a tag: untyped (following the type free) and the active ones, and the tag's own if it is
  # retired; each with the role its tags' pills take (the tag's page shows it in the heading's pill before Save)
  def gk_tags_type_options(selected_id)
    types = GkTags::Types.all.select { |t| t.active || t.id == selected_id }.reject(&:free?)
    none = [l(:label_gk_tags_untyped), '', { 'data-gk-tags-role' => GkTagsTag::NO_TYPE_ROLE }]
    options_for_select([none] + types.map { |t| [t.active ? t.name : "#{t.name} (#{l(:label_gk_tags_status_retired)})", t.id, { 'data-gk-tags-role' => t.category || GkTagsTag::NO_TYPE_ROLE }] },
                       selected_id)
  end

  # The objects that may be tagged (issue and the registered ones), with any stored key no longer registered
  def gk_tags_taggable_choices(stored = [])
    known = GkTags::Taggables.all.values.map { |e| [e.key, e.label_text] }
    known + (Array(stored) - known.map(&:first)).map { |k| [k, k] }
  end

  # A mark as gui_stuff's pill in its category: the mark, its note as the note icon with all of it in the
  # tooltip, the x; each part only when there is one. One's own mark shows its note and, with remove (the address that
  # takes it away), the x; someone else's shared mark shows her name and never a note or an x. The note's icon opens a
  # small popover with the whole note and, for the one who is signed in, Ändra lappen (the PATCH on her own marking). With
  # the appearance setting tags.note_text on for the viewer, the note is written out after its icon, cut short.
  def gk_tags_mark_pill(tagging, viewer = User.current, remove: nil)
    tag = tagging.tag
    own = tag.owner_id == viewer.id
    name = own ? tag.label : "#{tag.label} (#{GkTags::Json.user_visible?(tag.owner) ? tag.owner.name : l(:label_gk_tags_someone)})"
    note = own ? tagging.note.presence : nil
    edit = note && viewer == User.current ? gk_tags_note_path(tagging) : nil
    gk_gui_stuff_pill(name, role: tag.pill_role, note: note, note_icon: true, note_open: note.present? && GkTags.appearance?(GkTags::NOTE_TEXT, viewer),
                            note_hint: l(:text_gk_tags_mark_note_private), note_edit: edit,
                            remove: (own ? remove : nil), remove_title: l(:button_gk_tags_unmark))
  end

  def gk_tags_person(user) = respond_to?(:gk_records_user) ? gk_records_user(user) : link_to_user(user)

  # A tag's marking: none, warning or alarm, which take the roles of those alert levels
  def gk_tags_marking_options(selected)
    options_for_select([[l(:label_gk_tags_marking_none), '']] + GkTags::MARKINGS.map { |m| [l("label_gk_tags_marking_#{m}"), m] }, selected.to_s)
  end

  # The choices of a tag field for gui_stuff's chooser (select_search): the global tags in use (not merged, not
  # retired), each as it is written with its path when it has a parent, in its pill's role, with its aliases that are
  # not deprecated as words that also match exactly. What is written is chosen: a tag (a retired one the
  # object still bears too); a handle that is no tag yet as a new choice (data-gk-gui-new, made when the form is saved,
  # so that it comes back with "ny" after a refused save); one that does not resolve as written, for the message to
  # name. A tag whose own type has an icon names it for the chosen pill (data-gk-gui-icon, a pack's icon only with GK
  # Icons). except: ids left out (the parent's and the merge's lists); path: each option says its path (the parent).
  def gk_tags_select_options(written, except: nil, path: false)
    except = Array(except)
    tags = GkTagsTag.global.where(status: %w[free established managed]).where.not(id: except).includes(:type, :parent).sorted.to_a
    also = GkTagsAlias.where(tag_id: tags.map(&:id), deprecated: false).pluck(:tag_id, :handle).group_by(&:first)
    chosen = []
    more = []
    GkTags.split(written).uniq.each do |w|
      f = GkTags.resolve_ref(w)
      case f.status
      when :ok
        next if except.include?(f.tag.id)

        chosen << f.tag.id
        tags << f.tag unless tags.any? { |t| t.id == f.tag.id }
      when :new
        ref = f.type&.namespaced? ? "#{f.type.namespace}:#{f.key}" : f.key.to_s
        more << content_tag(:option, "##{ref}", value: ref, selected: true, data: { gk_gui_new: '1', gk_gui_role: GkTagsTag::NO_TYPE_ROLE })
      else
        h = w.sub(/\A#/, '')
        more << content_tag(:option, "##{h}", value: h, selected: true)
      end
    end
    opts = tags.map do |t|
      data = { gk_gui_role: t.pill_role, gk_gui_also: also[t.id]&.map(&:last)&.join(' ') }
      if (icon = t.type&.icon.presence) && (!icon.include?('/') || (defined?(::GkIcons) && ::GkIcons.exists?(icon)))
        data[:gk_gui_icon] = icon
        data[:gk_gui_icon_label] = t.type.name
      end
      data[:gk_tags_path] = t.path_label if path
      content_tag(:option, t.parent_id ? "##{t.ref} (#{t.path_label})" : "##{t.ref}", value: t.ref, selected: chosen.include?(t.id), data: data)
    end
    safe_join(opts + more)
  end

  # What a tag field's chooser is told: create, or the quiet row for one who may not create tags; the # before
  # the name; a new tag's pill in the role of a tag without type, in small letters as it is kept
  def gk_tags_select_data(create)
    { gk_gui_select: create ? 'create' : 'create-denied', gk_gui_select_prefix: '#', gk_gui_select_new_role: GkTagsTag::NO_TYPE_ROLE, gk_gui_select_lower: '1' }
  end

  # How much the tag is used on issues, with the tags merged into it: "12 ärenden i 3 projekt"
  def gk_tags_usage_text(usage) = l(:text_gk_tags_usage, issues: l(:label_gk_tags_n_issues, count: usage[0]), projects: l(:label_gk_tags_n_projects, count: usage[1]))

  # The status line's use: the issues as a link to the list with the tag, the projects and the last time it was put on
  def gk_tags_usage_line(tag, usage)
    issues, projects, last = usage
    return l(:text_gk_tags_used_none) if issues.zero?

    mark = "\u0001"
    before, after = l(:text_gk_tags_used_by, issues: mark, projects: l(:label_gk_tags_n_projects, count: projects), date: format_date(last)).split(mark, 2)
    safe_join([before, link_to(l(:label_gk_tags_n_issues, count: issues), gk_tags_issues_path(tag)), after])
  end
end
