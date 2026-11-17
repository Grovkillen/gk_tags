# frozen_string_literal: true

module GkTags
  # The box Taggar in the sidebar of a list (### sidebar): the tags on what the list shows now, grouped by tag type,
  # each with how many of the listed things carry it, so the number is always what a click finds. A parent counts the
  # things tagged with its descendants when their type inherits, as the filter finds them (Hierarchy.search_ids).
  # Only what the reader may see is counted: the list's own scope (visibility and its filters) gives the ids.
  # One query for the taggings and one for the tag tree, with a short cache per reader and list; never a query per
  # tag. Up to the limit the tags flow on rows per type (form C); over it the script turns the box into a
  # list with a bar per tag, search, sorting and the top per type with Visa alla (form D). Without script, form C.
  module Sidebar
    module_function

    CACHE_SECONDS = 60
    FEATURE = 'tags.sidebar'

    def on? = GkTags.ready? && GkTags.appearance?(FEATURE)

    # How many tags per type form D shows before Visa alla: the project's own number, else the instance's
    def top(project = nil)
      own = (GkTags.setting('sidebar_top_projects', {}) || {})[project&.id.to_s].to_i if project
      own&.positive? ? own : GkTags.appearance_value(FEATURE, 'sidebar_top', 5)
    end

    # How many tags in the box (those on what the list shows) before it turns into form D
    def limit = GkTags.appearance_value(FEATURE, 'sidebar_limit', 15)

    # { tag => count } for the things of one kind (the taggable's class name) whose ids the SQL gives
    def counts(taggable_type, ids_sql)
      key = ['gk_tags_sidebar', ::User.current.id, taggable_type, Digest::SHA256.hexdigest(ids_sql.to_s)]
      ids = ::Rails.cache.fetch(key, expires_in: CACHE_SECONDS) { count_ids(taggable_type, ids_sql) }
      tags = ::GkTagsTag.where(id: ids.keys).includes(:type).index_by(&:id)
      ids.filter_map { |id, n| (t = tags[id]) && [t, n] }.to_h
    end

    # tag id => number of distinct things, crediting each tagging to its tag (the one it was merged into) and to the
    # ancestors a search on them would find it from
    def count_ids(taggable_type, ids_sql)
      conn = ::ActiveRecord::Base.connection
      rows = conn.select_rows(<<~SQL)
        SELECT tg.taggable_id, tg.tag_id FROM gk_tags_taggings tg JOIN gk_tags_tags t ON t.id = tg.tag_id
        WHERE tg.taggable_type = #{conn.quote(taggable_type)} AND tg.removed_at IS NULL AND t.kind = 'tag'
          AND t.owner_id IS NULL AND tg.taggable_id IN (#{ids_sql})
      SQL
      return {} if rows.empty?

      tree = ::GkTagsTag.global.pluck(:id, :parent_id, :type_id, :merged_into_id).to_h { |i, p, ty, m| [i, [p, ty, m]] }
      inherit = Types.inherit_map
      credit = Hash.new { |h, id| h[id] = credited(id, tree, inherit) }
      found = Hash.new { |h, k| h[k] = {} }
      rows.each { |obj, tag| credit[tag.to_i].each { |c| found[c][obj] = true } }
      found.transform_values(&:size)
    end

    # The tag a tagging counts for (merged ones followed) and its ancestors, as long as each child's type inherits
    def credited(id, tree, inherit)
      seen = {}
      id = tree[id][2] while tree[id] && tree[id][2] && !seen[id] && (seen[id] = true)
      out = [id]
      cur = id
      ::GkTagsTag::MAX_DEPTH.times do
        parent, type_id, = tree[cur]
        break unless parent && (inherit.key?(type_id) ? inherit[type_id] : inherit[nil])

        out << parent
        cur = parent
      end
      out
    end

    # [[type or nil, [[tag, count], ...]], ...]: types in their order (no type last), tags by count, then handle
    def groups(counts)
      by = counts.group_by { |t, _| t.type }
      types = by.keys.compact.sort_by { |ty| [ty.position.to_i, ty.key.to_s] }
      (types + (by.key?(nil) ? [nil] : [])).map { |ty| [ty, by[ty].sort_by { |t, n| [-n, t.key] }] }
    end

    # The issue list's ids: its own scope (visible issues, its filters) in projects where the reader sees tags
    def issue_ids_sql(query, user = ::User.current)
      query.base_scope.where(::Project.allowed_to_condition(user, :gk_tags_view)).select("#{::Issue.table_name}.id").to_sql
    end

    # The issue list with the tag added to its filter Tagg, or taken away when it is chosen already (the last one taken
    # away removes the filter). Several chosen tags are one condition with the operator "is", which Redmine reads as
    # any of them: #a or #b. The list's columns, grouping, sorting and totals are kept, also for a saved query.
    def issue_params(query, tag)
      p = { set_filter: 1, f: [], op: {}, v: {} }
      query.filters.each do |field, o|
        p[:f] << field
        p[:op][field] = o[:operator]
        p[:v][field] = o[:values]
      end
      had = p[:f].include?('gk_tags') && p[:op]['gk_tags'] == '=' ? Array(p[:v]['gk_tags']).map(&:to_s) : []
      wanted = had.include?(tag.id.to_s) ? had - [tag.id.to_s] : (had + [tag.id.to_s]).uniq
      if wanted.empty?
        p[:f] -= ['gk_tags']
        p[:op].delete('gk_tags')
        p[:v].delete('gk_tags')
        p[:f] << '' if p[:f].empty? # core's way of saying "no filter" (otherwise the default status filter comes back)
      else
        p[:f] |= ['gk_tags']
        p[:op]['gk_tags'] = '='
        p[:v]['gk_tags'] = wanted
      end
      p[:c] = query.column_names
      p[:group_by] = query.group_by.to_s if query.group_by.present?
      p[:t] = query.totalable_names.map(&:to_s) if query.totalable_names.any?
      p[:sort] = query.sort_criteria.to_param
      p
    end

    # Another plugin's list filtered on tags (people's organizations and persons): the things carrying one of the
    # tags, or a descendant the search finds, as the issue filter does
    def filter_objects(scope, taggable_type, tag_ids)
      found = Hierarchy.search_ids(::GkTagsTag.where(id: Array(tag_ids).map(&:to_i)).to_a)
      found = [0] if found.empty?
      scope.where(id: ::GkTagsTagging.active.joins(:tag).where(taggable_type: taggable_type, tag_id: found, gk_tags_tags: { kind: 'tag' }).select(:taggable_id))
    end

    # The tag ids the list is filtered on now (shown as chosen)
    def chosen_ids(query)
      query.filters['gk_tags'] && query.filters['gk_tags'][:operator] == '=' ? Array(query.filters['gk_tags'][:values]).map(&:to_i) : []
    end
  end

  # The tab Taggar in a project's settings, for those who may set the box's number (gk_tags_sidebar_top), while the
  # box is on and the project uses tags, in core_stuff's register project_settings_tab. The register checks the
  # permission in the project; the condition here is the rest.
  module SidebarProjectTab
    def self.register!
      return nil unless GkTags.gui? # no tab without GK GUI Stuff (gate.rb)

      unless defined?(::GkCoreStuff::Tabs::PluginDsl)
        ::Rails.logger.warn("[gk_tags] gk_core_stuff is missing, although it is required: the tab Tags in a project's settings is not shown")
        return
      end

      ::Redmine::Plugin.find(:gk_tags).project_settings_tab :gk_tags_sidebar, partial: 'gk_tags_sidebar/project_tab', label: :label_gk_tags_tags,
                                                                              permission: :gk_tags_sidebar_top,
                                                                              if: ->(c) { c[:project] && Sidebar.on? && Access.on?(c[:project]) }
    end
  end

  # The box under the issue list's saved queries, on the list only (not the issue page, which shares the sidebar)
  class SidebarHooks < Redmine::Hook::ViewListener
    include GkTags::Gate::Listener # silent without GK GUI Stuff (gate.rb)

    def view_issues_sidebar_queries_bottom(context = {})
      c = context[:controller]
      return '' unless Sidebar.on? && c.is_a?(::IssuesController) && c.action_name == 'index'

      query = c.instance_variable_get(:@query)
      return '' unless query.is_a?(::IssueQuery) && query.valid?

      project = context[:project]
      return '' if project && !Access.on?(project)

      counts = Sidebar.counts('Issue', Sidebar.issue_ids_sql(query))
      return '' if counts.empty?

      view = context[:hook_caller]
      view.render(partial: 'gk_tags_sidebar/box',
                  locals: { groups: Sidebar.groups(counts), top: Sidebar.top(project), limit: Sidebar.limit, chosen: Sidebar.chosen_ids(query),
                            link: ->(tag) { view.url_for(Sidebar.issue_params(query, tag).merge(controller: 'issues', action: 'index', project_id: project&.identifier)) } })
    end
  end
end
