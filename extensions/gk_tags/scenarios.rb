# frozen_string_literal: true

module GkTags
  # tags' steps and expectations in scenarios. The data is under tags: in scenario.yml; a handle is a key into the
  # locale (tags.handles.<key>), and so are a managed tag's name (tags.names.<key>), a mark's name (tags.marks.<key>)
  # and a slip (tags.notes.<key>). Taggings are saved through the object as the person who writes them, as the form
  # saves them. Lifecycle steps are made by the first active administrator. Expectations look things up from the
  # scenario itself and never use issue: with status:.
  module Scenarios
    PERMS = { 'view' => :gk_tags_view, 'tag' => :gk_tags_tag, 'create_free' => :gk_tags_create_free }.freeze

    module_function

    def data(ctx) = ctx.scenario.data['tags'] || {}
    def handle(s, key) = GkTags.normalize(s.t(:tags, :handles, key))
    def tag(s, key) = GkTags.resolve(handle(s, key))
    def issue(ctx, key) = ::GkScenarios::Expect.issue_for(ctx, key.to_s)
    def user(ctx, key) = ::User.find_by_login(::GkScenarios::Expect.login(ctx, key.to_s))
    def admin = ::User.active.where(admin: true).order(:id).first

    def note_of(ctx, issue_key, note_key)
      i = issue(ctx, issue_key) or return nil
      i.journals.detect { |j| j.notes.to_s == ctx.scenario.t(:issues, issue_key, :notes, note_key) }
    end

    def result(want, got) = { 'ok' => want.to_s == got.to_s, 'want' => want.to_s, 'got' => got.to_s }

    # A scenario that uses marks or focus switches the declared function on first
    FILTER_FEATURES = { 'gk_marked' => 'tags.marks', 'gk_focus' => 'tags.focus' }.freeze

    def feature_on!(key)
      return unless defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register) && ::GkRecords::Features.find(key)
      return if ::GkRecords::Features.on?(key)

      ::GkRecords::Features.set!(key, true, reason: 'scenario')
    end

    # A step leaves the functions as it found them, as a new installation has them: on only for what the step makes
    def feature_for_step!(key, switched)
      switched << key if feature_on!(key)
    end

    # What the type expectations share. A type of the scenario's own is made inside the expectation's transaction from
    # type: { key, exclusive, allowed_on, required_for, namespace (a handle key), inherit_parents, repeat_keys }; its
    # name is tags.types.<key> in the locale when there.
    def make_type(s, spec)
      GkTags::Types.all # the general types first, so that a type of the scenario's own never stands in for them
      spec = (spec || {}).to_h { |k, v| [k.to_s, v] }
      key = spec['key'].to_s
      names = s.t?(:tags, :types, key) ? { s.locale.to_s => s.t(:tags, :types, key) } : { 'sv' => key }
      ::GkTagsType.create!(key: key, name: names.values.first, exclusive: spec['exclusive'] == true,
                          allowed_on_list: Array(spec['allowed_on']), required_for_list: Array(spec['required_for']),
                          namespace: spec['namespace'] ? handle(s, spec['namespace']) : nil,
                          inherit_parents: spec.key?('inherit_parents') ? spec['inherit_parents'] == true : true,
                          repeat_keys: spec['repeat_keys'] == true, position: 100)
    end

    # A managed tag of the type (a handle key), under a parent when given
    def make_tag(s, key, type, parent = nil)
      ::GkTagsTag.create!(key: handle(s, key), kind: 'tag', status: 'managed', type_id: type&.id, parent_id: parent&.id, name: s.t(:tags, :handles, key))
    end

    # The object of an expectation: an issue by its key, or with kind: organization or person, people's by its key
    # (not "on:": YAML reads a bare on as true, so the key never arrives)
    def object_of(ctx, e, key)
      case e['kind'].to_s
      when 'organization' then defined?(::GkPeople) && ::GkPeople.respond_to?(:scenario_org) ? ::GkPeople.scenario_org(ctx, key) : nil
      when 'person' then defined?(::GkPeople) && ::GkPeople.respond_to?(:scenario_person) ? ::GkPeople.scenario_person(ctx, key) : nil
      else issue(ctx, key)
      end
    end

    # Write the tag field of the object as the person and save it (the issue with a journal, as the form does)
    def write!(ctx, obj, user, text)
      ok = nil
      ctx.as(user) do
        obj.init_journal(user) if obj.is_a?(::Issue)
        obj.gk_tag_list = text
        ok = obj.save
      end
      ok
    end

    # A row of tags.taggings is saved through the object as the person in by:, the way the form saves it: the issue
    # with its tag field and a journal (its history line), an organization or a person with gk_tag_list (the event
    # Taggar ändrade in records). The types' rules run on save (Tagging.check: exclusive, allowed_on, required_for,
    # and a free tag only for whoever may create one). The person must be allowed to change the object's tags as the
    # form decides (Taggables.tag?: the issue's Access.tag?, which makes gk_tag_list a safe attribute; people's
    # manage? for organizations and persons). The list written is the object's tags as they are (each by its ref, as
    # the field shows them) followed by the wanted ones not on it yet, so a tag the scenario did not name is never
    # removed. Nothing is written when every wanted tag is already on the object (created again on top of itself). A
    # refusal stops the step with the rule's message. True when the object got a tag.
    def tag_through!(ctx, obj, by, keys, note_key)
      s = ctx.scenario
      obj = obj.class.find_by(id: obj.id) || obj # fresh: the scenario's own copy may be stale (lock_version)
      have = GkTags::Tagging.tags_of(obj)
      on = ->(w) { w.status == :ok && have.any? { |t| t.id == w.tag.id } }
      written = Array(keys).map { |k| ctx.made['tg_value'][k.to_s]&.ref || s.t(:tags, :handles, k).to_s }
      wanted = GkTags::Tagging.read(written.join(' '))
      return false if wanted.all?(&on)
      raise ::GkScenarios::Error, "tags tagging #{note_key}: no person" unless by
      unless GkTags::Taggables.tag?(obj, by)
        raise ::GkScenarios::Error, "tags tagging #{note_key}: #{::I18n.t(:error_gk_tags_may_not_tag)}"
      end

      list = (have.map(&:ref) + wanted.reject(&on).map(&:written)).uniq.join(' ')
      raise ::GkScenarios::Error, "tags tagging #{note_key}: #{obj.errors.full_messages.join(', ')}" unless write!(ctx, obj, by, list)

      GkTags::Tagging.tags_of(obj).size > have.size
    end

    def handles_text(s, keys) = Array(keys).map { |k| s.t(:tags, :handles, k) }.join(' ')

    # What the step tags_types reads. A type of the scenario: tags.types: { key, category (1 to 12), icon, exclusive,
    # allowed_on, required_for, namespace (a handle key), inherit_parents, repeat_keys }; its name is
    # tags.types.<key> and its description tags.type_descriptions.<key> (when there) in the scenario's language.
    def type_attrs(s, spec)
      key = spec['key'].to_s
      desc = s.t?(:tags, :type_descriptions, key)
      { key: key, name: (s.t?(:tags, :types, key) || key).to_s, description: desc&.to_s,
        category: GkTags.category(spec['category']), icon: spec['icon'].presence, exclusive: spec['exclusive'] == true,
        allowed_on_list: Array(spec['allowed_on']), required_for_list: Array(spec['required_for']),
        namespace: spec['namespace'] ? handle(s, spec['namespace']) : nil,
        inherit_parents: spec.key?('inherit_parents') ? spec['inherit_parents'] == true : true,
        repeat_keys: spec['repeat_keys'] == true, position: (::GkTagsType.maximum(:position) || 0) + 1 }
    end

    # A tag value of the scenario as it may already be there: of the type under the parent (a type with repeat_keys),
    # of the type (a namespaced type), or the global tag with the key that has the type or none
    def find_value(key, type, parent)
      scope = ::GkTagsTag.global.where(key: key)
      return scope.find_by(type_id: type.id, parent_id: parent&.id) if type&.repeat_keys
      return scope.find_by(type_id: type.id) if type&.namespaced?

      ns = GkTags::Types.namespaced_ids
      t = scope.order(:id).to_a.detect { |x| !ns.include?(x.type_id) && (x.type_id.nil? || x.type_id == type&.id) }
      GkTags.follow_merged(t)
    end

    # The object of a row under tags.taggings: issue:, or organization: or person: (people's, by the scenario's key; one
    # the import or the sync brought is found by its name in the locale). [object, the key in the report]
    def tagging_target(ctx, row)
      if row['organization']
        obj = ctx.made['organization'][row['organization'].to_s] || object_of(ctx, { 'kind' => 'organization' }, row['organization'])
        [obj, "organization:#{row['organization']}:#{row['by']}"]
      elsif row['person']
        obj = ctx.made['person'][row['person'].to_s] || object_of(ctx, { 'kind' => 'person' }, row['person'])
        [obj, "person:#{row['person']}:#{row['by']}"]
      else
        [ctx.get(:issue, row['issue']), "#{row['issue']}:#{row['by']}"]
      end
    end

    def lifecycle!(ok, tag, what)
      raise ::GkScenarios::Error, "tags value #{tag.key} (#{what}): #{tag.errors.full_messages.join(', ')}" unless ok
    end

    def listed_with_tag?(ctx, user, tag, issue)
      ids = []
      ctx.as(user) do
        q = ::IssueQuery.new(name: '_')
        q.user = user
        q.filters = { 'status_id' => { operator: '*', values: [''] } }
        q.add_filter('gk_tags', '=', [tag.id.to_s])
        ids = q.issue_ids
      end
      ids.include?(issue&.id)
    end

    def register!
      return unless defined?(::GkScenarios::Steps)

      ::GkScenarios::Steps.register('tags_permissions', plugin: :gk_tags, order: 150) do |ctx|
        Array(data(ctx)['permissions']).each do |row|
          role = ctx.get(:role, row['role'])
          missing = Array(row['may']).map { |m| PERMS.fetch(m.to_s) } - role.permissions
          missing.each { |perm| role.add_permission!(perm) }
          ctx.note(:tg_permission, row['role'], role, missing.any?)
        end
      end

      # The scenario's tag types and managed tags as data that stays (tags.types and tags.values), before the issues,
      # made by the first active administrator the way Administration > Taggar makes them: a type through TypeLifecycle
      # (its event in records), a tag made and then promoted (managed, its name from the locale: tags.names.<key> when
      # there, else the handle as written), with its type and its parent (parent: a value key earlier in the list; the
      # hierarchy, e.g. Jämtland/Bräcke). values: { key (a handle key), type, parent, marking (warning or alarm) }.
      # A type is found again by its key and is then left as it is; a tag by its handle, type and parent, and one that
      # is there without a type or a parent gets them, one not managed is promoted.
      ::GkScenarios::Steps.register('tags_types', plugin: :gk_tags, order: 156) do |ctx|
        s = ctx.scenario
        d = data(ctx)
        next if Array(d['types']).empty? && Array(d['values']).empty?
        raise ::GkScenarios::Error, 'tags: no table gk_tags_types (migration 003)' unless GkTags::Types.ready?

        adm = admin or raise ::GkScenarios::Error, 'tags: no active administrator'
        GkTags::Types.all # the general types first, so that the scenario's own never keep them from being seeded
        Array(d['types']).each do |spec|
          type = ::GkTagsType.find_by(key: spec['key'].to_s)
          created = type.nil?
          if created
            type = ::GkTagsType.new
            unless GkTags::TypeLifecycle.save(type, adm, type_attrs(s, spec))
              raise ::GkScenarios::Error, "tags type #{spec['key']}: #{type.errors.full_messages.join(', ')}"
            end
          end
          ctx.note(:tg_type, spec['key'], type, created)
        end
        Array(d['values']).each do |row|
          type = nil
          if row['type']
            type = ::GkTagsType.find_by(key: row['type'].to_s) or raise ::GkScenarios::Error, "tags value #{row['key']}: no type #{row['type']}"
          end
          parent = row['parent'] ? ctx.get(:tg_value, row['parent']) : nil
          key = handle(s, row['key']) or raise ::GkScenarios::Error, "tags value #{row['key']}: not a handle"
          tag = find_value(key, type, parent)
          created = tag.nil?
          tag ||= ::GkTagsTag.create!(key: key, kind: 'tag', status: 'free', type_id: type&.id, parent_id: parent&.id, created_by_id: adm.id)
          lifecycle!(GkTags::Lifecycle.set_type(tag, adm, type), tag, 'type') if type && tag.type_id.nil?
          lifecycle!(GkTags::Lifecycle.move(tag, adm, parent), tag, 'parent') if parent && tag.parent_id.nil?
          if %w[free established].include?(tag.status)
            name = (s.t?(:tags, :names, row['key']) || s.t(:tags, :handles, row['key'])).to_s
            lifecycle!(GkTags::Lifecycle.promote(tag, adm, name: name, marking: row['marking']), tag, 'managed')
          end
          ctx.note(:tg_value, row['key'], tag.reload, created)
        end
      end

      # After the issues: taggings (in order, as the person who writes them), the lifecycle, marks and focus
      ::GkScenarios::Steps.register('tags', plugin: :gk_tags, order: 270) do |ctx|
        s = ctx.scenario
        d = data(ctx)
        # The plugin's settings the scenario relies on (the manager's responsibility)
        if d['settings'].is_a?(Hash) && d['settings'].any?
          cur = (::Setting.plugin_gk_tags || {}).to_h.transform_keys(&:to_s)
          want = cur.merge(d['settings'].to_h { |k, v| [k.to_s, v.to_s] })
          ::Setting.plugin_gk_tags = want if want != cur
          ctx.note(:tg_setting, d['settings'].keys.join(','), nil, want != cur)
        end
        # Each row is saved through the object as the form saves it (tag_through!), so the types' rules run and a
        # refusal stops the step.
        switched = []
        feature_for_step!('tags.objects', switched) if Array(d['taggings']).any? { |row| row['organization'] || row['person'] }
        Array(d['taggings']).each do |row|
          obj, note_key = tagging_target(ctx, row)
          raise ::GkScenarios::Error, "tags tagging #{note_key}: no object" unless obj

          ctx.note(:tg_tagging, note_key, obj, tag_through!(ctx, obj, ctx.get(:user, row['by']), row['tags'], note_key))
        end
        adm = admin
        Array(d['lifecycle']).each do |row|
          t = tag(s, row['tag']) or raise ::GkScenarios::Error, "tag #{row['tag']}"
          done = case row['do']
                 when 'promote'
                   t.status == 'managed' ? false : GkTags::Lifecycle.promote(t, adm, name: s.t(:tags, :names, row['tag']), marking: row['marking'])
                 when 'alias'
                   h = handle(s, row['alias'])
                   ::GkTagsAlias.exists?(handle: h) ? false : GkTags::Lifecycle.add_alias(t, adm, h, language: row['language']).first
                 when 'rename'
                   to = handle(s, row['to'])
                   t.key == to ? false : GkTags::Lifecycle.rename(t, adm, to)
                 when 'merge'
                   into = tag(s, row['into'])
                   t.id == into.id ? false : GkTags::Lifecycle.merge(t, into, adm).first
                 when 'retire'
                   t.status == 'retired' ? false : GkTags::Lifecycle.retire(t, adm) && true
                 else raise ::GkScenarios::Error, "lifecycle #{row['do']}"
                 end
          ctx.note(:tg_lifecycle, "#{row['tag']}:#{row['do']}", t, done == true)
        end
        feature_for_step!('tags.marks', switched) if Array(d['marks']).any?
        feature_for_step!('tags.focus', switched) if Array(d['focus']).any?
        Array(d['marks']).each do |row|
          by = ctx.get(:user, row['by'])
          object = row['note'] ? note_of(ctx, row['note'][0], row['note'][1]) : ctx.get(:issue, row['issue'])
          raise ::GkScenarios::Error, "mark #{row.inspect}" unless object

          mark = nil
          if row['mark']
            name = s.t(:tags, :marks, row['mark'])
            mark = ::GkTagsTag.find_by(kind: 'mark', owner_id: by.id, name: name) || GkTags::Marks.create(by, name, category: row['category'], shared: row['shared'] == true)
          end
          had = GkTags::Marks.on(object, by).any? { |x| x.tag.owner_id == by.id }
          GkTags::Marks.mark(object, by, mark, note: row['slip'] ? s.t(:tags, :notes, row['slip']) : nil)
          ctx.note(:tg_mark, "#{row['by']}:#{row['issue'] || row['note'].join('/')}", object, !had)
        end
        Array(d['focus']).each do |row|
          by = ctx.get(:user, row['by'])
          Array(row['issues']).each do |k|
            res, = GkTags::Focus.add(ctx.get(:issue, k), by)
            ctx.note(:tg_focus, "#{row['by']}:#{k}", by, res == :added)
          end
        end
      ensure
        # Also when the step is stopped by an error, so that a failed step leaves the functions as it found them
        Array(switched).each { |key| ::GkRecords::Features.set!(key, false, reason: 'scenario') }
      end

      # The issue's tags, as their keys (handles by scenario key), sorted.
      # With kind: organization or person, the tags of people's object by its key
      ::GkScenarios::Expect.register('tg_tags') do |ctx, e|
        i = object_of(ctx, e, e['tg_tags'])
        want = Array(e['equals']).map { |k| handle(ctx.scenario, k) }.sort.join(' ')
        result(want, i ? GkTags::Tagging.tags_of(i).map(&:key).sort.join(' ') : '-')
      end

      # A tag of the scenario as it is (tg_tag: a handle key; path: the handle keys from the root when the key alone is
      # ambiguous): only what is given is compared, type: the type's key, path: [handle keys from the root down],
      # status
      ::GkScenarios::Expect.register('tg_tag') do |ctx, e|
        s = ctx.scenario
        path = Array(e['path']).map { |k| handle(s, k) }
        t = tag(s, e['tg_tag']) || (path.any? ? GkTags.resolve(path.join('/')) : nil)
        want = []
        got = []
        if e.key?('type')
          want << "type #{e['type']}"
          got << "type #{t&.type&.key || '-'}"
        end
        if e.key?('path')
          want << "path #{path.join('/')}"
          got << "path #{t&.path_key || '-'}"
        end
        if e.key?('status')
          want << "status #{e['status']}"
          got << "status #{t&.status || '-'}"
        end
        t ? result(want.join(', '), got.join(', ')) : { 'ok' => false, 'want' => want.join(', '), 'got' => 'no tag' }
      end

      # A tag type as it is (tg_type: its key): only the rules given are compared (exclusive, allowed_on, required_for,
      # namespace as a handle key, inherit_parents, repeat_keys, category, active), and name: true for its name in the
      # scenario's language (tags.types.<key>)
      ::GkScenarios::Expect.register('tg_type') do |ctx, e|
        s = ctx.scenario
        type = GkTags::Types.ready? ? ::GkTagsType.find_by(key: e['tg_type'].to_s) : nil
        next({ 'ok' => false, 'want' => e['tg_type'].to_s, 'got' => 'no type' }) unless type

        want = {}
        got = {}
        %w[exclusive inherit_parents repeat_keys active].each do |f|
          next unless e.key?(f)

          want[f] = e[f] == true
          got[f] = type.public_send(f) == true
        end
        { 'allowed_on' => :allowed_on_list, 'required_for' => :required_for_list }.each do |f, m|
          next unless e.key?(f)

          want[f] = Array(e[f]).map(&:to_s).sort
          got[f] = type.public_send(m).sort
        end
        if e.key?('namespace')
          want['namespace'] = handle(s, e['namespace'])
          got['namespace'] = type.namespace
        end
        if e.key?('category')
          want['category'] = e['category'].to_s
          got['category'] = type.category.to_s
        end
        if e['name']
          want['name'] = s.t(:tags, :types, e['tg_type'])
          got['name'] = type[:name].to_s
        end
        { 'ok' => got == want, 'want' => want.to_json, 'got' => got.to_json }
      end

      # A tag's status
      ::GkScenarios::Expect.register('tg_status') do |ctx, e|
        t = tag(ctx.scenario, e['tg_status'])
        result(e['equals'], t&.status || '-')
      end

      # A handle resolves to a tag (an alias, a former key, a merged tag)
      ::GkScenarios::Expect.register('tg_resolve') do |ctx, e|
        t = GkTags.resolve(handle(ctx.scenario, e['tg_resolve']))
        result(handle(ctx.scenario, e['equals']), t&.key || '-')
      end

      # How many issues the issue list gives a person with a filter: tag (with merged ones), marked or in focus
      ::GkScenarios::Expect.register('tg_filter') do |ctx, e|
        u = user(ctx, e['as'])
        f = e['tg_filter'].to_s
        feature_on!(FILTER_FEATURES[f]) if FILTER_FEATURES[f]
        v = f == 'gk_tags' ? [tag(ctx.scenario, e['tag'])&.id.to_s] : [e['who'].to_s]
        got = nil
        ctx.as(u) do
          q = ::IssueQuery.new(name: '_')
          q.user = u
          q.filters = { 'status_id' => { operator: '*', values: [''] } }
          q.add_filter(f, e['op'] || '=', v)
          got = q.issue_count
        end
        result(e['equals'], got)
      end

      # The box Taggar in the issue list's sidebar: the number beside the tag is what a click on it gives (the filter's
      # count, for the person, merged and descendant tags included), equals when given, and the count asks the database
      # at most queries_max times (one for the taggings, a few for the tag tree; never one per tag). The cache is not used.
      ::GkScenarios::Expect.register('tg_sidebar') do |ctx, e|
        u = user(ctx, e['as'])
        feature_on!(GkTags::Sidebar::FEATURE)
        t = tag(ctx.scenario, e['tg_sidebar'])
        got = filter = nil
        queries = 0
        ctx.as(u) do
          q = ::IssueQuery.new(name: '_')
          q.user = u
          q.filters = { 'status_id' => { operator: '*', values: [''] } }
          sql = GkTags::Sidebar.issue_ids_sql(q, u)
          counter = ->(*, payload) { queries += 1 unless payload[:name] == 'SCHEMA' || payload[:cached] }
          # Once first, so that what other checks left cold (core's settings cache, emptied when a check writes a
          # setting) is read before counting: the count is the steady one, the property is "never one per tag"
          GkTags::Sidebar.count_ids('Issue', sql)
          ::ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { got = GkTags::Sidebar.count_ids('Issue', sql)[t&.id].to_i }
          q.add_filter('gk_tags', '=', [t&.id.to_s])
          filter = q.issue_count
        end
        ok = got == filter && (e['equals'].nil? || got == e['equals'].to_i) && (e['queries_max'].nil? || queries <= e['queries_max'].to_i)
        { 'ok' => ok, 'want' => "#{"#{e['equals']}, " if e['equals']}as the filter#{", at most #{e['queries_max']} queries" if e['queries_max']}",
          'got' => "#{got}, the filter #{filter}, #{queries} queries" }
      end

      # Is the issue in the list for a person with a filter (includes or excludes by issue key)
      ::GkScenarios::Expect.register('tg_listed') do |ctx, e|
        u = user(ctx, e['as'])
        feature_on!(FILTER_FEATURES[e['tg_listed'].to_s]) if FILTER_FEATURES[e['tg_listed'].to_s]
        ids = nil
        ctx.as(u) do
          q = ::IssueQuery.new(name: '_')
          q.user = u
          q.filters = { 'status_id' => { operator: '*', values: [''] } }
          q.add_filter(e['tg_listed'].to_s, '=', [e['who'].to_s])
          ids = q.issue_ids
        end
        inc = Array(e['includes']).map { |k| issue(ctx, k)&.id }
        exc = Array(e['excludes']).map { |k| issue(ctx, k)&.id }
        ok = (inc - ids).empty? && (exc & ids).empty?
        { 'ok' => ok, 'want' => "in #{e['includes'].inspect} not #{e['excludes'].inspect}", 'got' => ids.size.to_s }
      end

      # May the person change the issue's tags
      ::GkScenarios::Expect.register('tg_may_tag') do |ctx, e|
        i = issue(ctx, e['tg_may_tag'])
        u = user(ctx, e['as'])
        result(e['equals'] != false, !!(i && u && GkTags::Access.tag?(i, u)))
      end

      # Writing the tag field as a person (rolled back): is it saved (equals true) or refused? With journal: also how
      # many tag lines the update's journal got
      ::GkScenarios::Expect.register('tg_write') do |ctx, e|
        i = issue(ctx, e['tg_write'])
        u = user(ctx, e['as'])
        text = Array(e['handles']).map { |k| ctx.scenario.t(:tags, :handles, k) }.join(' ')
        ok = nil
        lines = nil
        ::Issue.transaction do
          ctx.as(u) do
            i.init_journal(u)
            i.gk_tag_list = text
            ok = i.save
            lines = ok ? ::JournalDetail.where(journal_id: i.current_journal&.id, prop_key: GkTags::IssuePatch::JOURNAL_KEY).count : 0
          end
          raise ::ActiveRecord::Rollback
        end
        i.reload
        e.key?('lines') ? result("#{e['equals'] != false} #{e['lines']}", "#{ok} #{lines}") : result(e['equals'] != false, ok)
      end

      # The marks on an issue or a note a person sees (her own and shared ones)
      ::GkScenarios::Expect.register('tg_marks_seen') do |ctx, e|
        object = e['note'] ? note_of(ctx, e['tg_marks_seen'], e['note']) : issue(ctx, e['tg_marks_seen'])
        u = user(ctx, e['as'])
        result(e['equals'], object && u ? GkTags::Marks.on(object, u).size : '-')
      end

      # Changing the note of one's own marking (rolled back): on the issue, or with note: true on a note made for the
      # check. Two markings of the person's default mark with notes of their own; a new note is kept, the other
      # marking's note is refused, an empty note takes it away, both without a note is refused, and someone else
      # (other:) cannot change it
      ::GkScenarios::Expect.register('tg_mark_renote') do |ctx, e|
        i = issue(ctx, e['tg_mark_renote'])
        u = user(ctx, e['as'])
        other = user(ctx, e['other'])
        want = 'true renote c; false same; true -; false same_bare; false gone'
        next({ 'ok' => false, 'want' => want, 'got' => 'no issue or person' }) unless i && u && other

        got = nil
        ::Issue.transaction do
          ctx.as(u) do
            object = e['note'] ? ::Journal.create!(journalized: i, user: u, notes: 'tg_mark_renote') : i
            first = GkTags::Marks.mark(object, u, nil, note: 'renote a')
            second = first && GkTags::Marks.mark(object, u, first.tag, note: 'renote b')
            if first && second && first.id != second.id
              steps = [GkTags::Personal.renote(first, u, 'renote c'), [nil, first.reload.note],
                       GkTags::Personal.renote(first, u, 'renote b'), GkTags::Personal.renote(first, u, ''),
                       GkTags::Personal.renote(second, u, ''), GkTags::Personal.renote(first, other, 'renote d')]
              got = [[steps[0][0], steps[1][1]], steps[2], [steps[3][0], first.reload.note || '-'], steps[4], steps[5]]
                    .map { |ok, why| "#{ok} #{why || '-'}" }.join('; ')
            else
              got = 'no two markings'
            end
          end
          raise ::ActiveRecord::Rollback
        end
        result(want, got)
      end

      # A person's focus list in order (issue keys); the order is priority, then due date
      ::GkScenarios::Expect.register('tg_focus') do |ctx, e|
        u = user(ctx, e['tg_focus'])
        want = Array(e['equals']).map { |k| issue(ctx, k)&.id }.join(',')
        result(want, u ? GkTags::Focus.list(u).map(&:taggable_id).join(',') : '-')
      end

      # Putting issues in focus as a person (rolled back): the result of the last one (added, full, already)
      ::GkScenarios::Expect.register('tg_focus_add') do |ctx, e|
        u = user(ctx, e['tg_focus_add'])
        got = nil
        ::GkTagsTagging.transaction do
          Array(e['issues']).each { |k| got, = GkTags::Focus.add(issue(ctx, k), u) }
          raise ::ActiveRecord::Rollback
        end
        result(e['equals'], got)
      end

      # Fill the list up to the cap, put one more in naming the issue it replaces (one step), then Ångra. equals: the
      # list after the replace, undone: after the undo (issue keys, any order)
      ::GkScenarios::Expect.register('tg_focus_replace') do |ctx, e|
        u = user(ctx, e['tg_focus_replace'])
        keys = ->(list) { Array(list).map { |k| issue(ctx, k)&.id }.compact.sort.join(',') }
        now = -> { GkTags::Focus.taggings(u).map(&:taggable_id).sort.join(',') }
        got = nil
        ::GkTagsTagging.transaction do
          Array(e['fill']).each { |k| GkTags::Focus.add(issue(ctx, k), u) }
          added = issue(ctx, e['add'])
          res, old = GkTags::Focus.add(added, u, replace: issue(ctx, e['replace'])&.id)
          after = now.call
          GkTags::Focus.undo(u, drop: added&.id, restore: old)
          got = "#{res} #{after} / #{now.call}"
          raise ::ActiveRecord::Rollback
        end
        result("replaced #{keys.call(e['equals'])} / #{keys.call(e['undone'])}", got)
      end

      # Tidigare fokus, rolled back: with an optional legacy tagging from before the events (legacy: { issue:,
      # from:, to: } in days from today), the issues in the history in mode issues or days with n
      ::GkScenarios::Expect.register('tg_focus_history') do |ctx, e|
        u = user(ctx, e['tg_focus_history'])
        got = nil
        ::GkTagsTagging.transaction do
          if (l = e['legacy']).is_a?(Hash)
            i = issue(ctx, l['issue'])
            ::GkTagsTagging.create!(tag_id: GkTags::Focus.tag_for(u).id, taggable_type: 'Issue', taggable_id: i.id, project_id: i.project_id,
                                   tagger_id: u.id, source: 'manual', created_at: ::Time.current + l['from'].to_i.days,
                                   removed_at: l.key?('to') ? ::Time.current + l['to'].to_i.days : nil, removed_by_id: l.key?('to') ? u.id : nil)
          end
          got = GkTags::FocusHistory.rows(u, mode: e['mode'], n: e['n']).map(&:issue_id).uniq.sort.join(',')
          raise ::ActiveRecord::Rollback
        end
        result(Array(e['equals']).map { |k| issue(ctx, k)&.id }.compact.sort.join(','), got)
      end

      # Does a person (as:) see another's focus, current or history (scope:), by the sharing rules; manager: a
      # responsibility key in place of the setting
      ::GkScenarios::Expect.register('tg_focus_sees') do |ctx, e|
        owner = user(ctx, e['tg_focus_sees'])
        viewer = user(ctx, e['as'])
        key = e['manager'] ? e['manager'].to_s : GkTags::FocusSharing.manager_key
        result(e['equals'] != false, !!(owner && viewer && GkTags::FocusSharing.sees?(owner, viewer, e['scope'] || 'current', key: key)))
      end

      # Sharing and taking back, rolled back: whether the viewer sees the owner's focus before, after sharing it with
      # a Redmine group (group:) or a single user (user:), and after taking it back; events: how many sharing events
      # that wrote (with records)
      ::GkScenarios::Expect.register('tg_focus_share') do |ctx, e|
        owner = user(ctx, e['tg_focus_share'])
        viewer = user(ctx, e['as'])
        scope = (e['scope'] || 'current').to_s
        kind, id = if e['group'] then ['group', ::Group.givable.find_by(lastname: ctx.scenario.t(:groups, e['group'], :name))&.id]
                   elsif e['user'] then ['user', user(ctx, e['user'])&.id]
                   end
        raise ::GkScenarios::Error, "tg_focus_share #{e['key']}: group: or user:" unless kind && id

        seen = []
        events = 0
        ::GkTagsFocusShare.transaction do
          last = defined?(::GkRecordsEvent) ? ::GkRecordsEvent.maximum(:id).to_i : 0
          seen << GkTags::FocusSharing.sees?(owner, viewer, scope)
          GkTags::FocusSharing.share(owner, scope, kind, id)
          seen << GkTags::FocusSharing.sees?(owner, viewer, scope)
          GkTags::FocusSharing.unshare(owner, scope, kind, id)
          seen << GkTags::FocusSharing.sees?(owner, viewer, scope)
          events = ::GkRecordsEvent.where(kind: GkTags::FocusSharing::EVENT_KINDS).where('id > ?', last).count if defined?(::GkRecordsEvent)
          raise ::ActiveRecord::Rollback
        end
        want = Array(e['equals']).join(' ')
        got = seen.join(' ')
        if e.key?('events')
          want += " events #{e['events']}"
          got += " events #{events}"
        end
        result(want, got)
      end

      # #tag in rendered text: which handles become links (by scenario key), never #123
      ::GkScenarios::Expect.register('tg_text_links') do |ctx, e|
        s = ctx.scenario
        text = "<p>#{Array(e['tg_text_links']).map { |k| "##{s.t(:tags, :handles, k)}" }.join(' ')} #123</p>"
        html = GkTags::TextLinks.link(text)
        linked = html.scan(%r{/gk_tags/t/([^"]+)"}).flatten.map { |k| CGI.unescape(k) }.sort.join(' ')
        want = Array(e['equals']).map { |k| handle(s, k) }.sort.join(' ')
        result(want, linked)
      end

      # The general types are there, also after the scenario emptied every table (seeded when the table has no rows).
      # equals: the type keys that must be there (others may be too).
      ::GkScenarios::Expect.register('tg_types') do |_ctx, e|
        want = Array(e['equals']).map(&:to_s).sort
        have = GkTags::Types.all.map(&:key)
        result(want.join(' '), (want & have).sort.join(' '))
      end

      # A type of the scenario's own (type:) with tags of it (tags: handle keys), then the tag field written as a
      # person (as:) on an issue, or with kind: organization or person on people's object, with handles:. equals:
      # saved (true) or refused (false). Shows exclusive, allowed_on and required_for.
      ::GkScenarios::Expect.register('tg_type_write') do |ctx, e|
        s = ctx.scenario
        u = user(ctx, e['as'])
        feature_on!('tags.objects') if e['kind']
        ok = nil
        ::GkTagsType.transaction do
          type = make_type(s, e['type'])
          Array(e['tags']).each { |k| make_tag(s, k, type) }
          obj = object_of(ctx, e, e['tg_type_write']) or raise ::GkScenarios::Error, "tg_type_write #{e['key']}: no object #{e['tg_type_write']}"
          ok = write!(ctx, obj, u, handles_text(s, e['handles']))
          raise ::ActiveRecord::Rollback
        end
        result(e['equals'] != false, ok)
      end

      # A type with a namespace (type: with namespace: a handle key), then "#<namespace>:<value>" (write: [namespace
      # key, value key]) written in the tag field of an issue as a person.
      # equals: [type key, value key]: the issue got the value as a tag of the type, and the reference resolves to it.
      ::GkScenarios::Expect.register('tg_namespace') do |ctx, e|
        s = ctx.scenario
        u = user(ctx, e['as'])
        ns_key, value_key = Array(e['write'])
        got = nil
        ::GkTagsType.transaction do
          type = make_type(s, e['type'])
          i = issue(ctx, e['tg_namespace']) or raise ::GkScenarios::Error, "tg_namespace #{e['key']}: no issue"
          ref = "#{s.t(:tags, :handles, ns_key)}:#{s.t(:tags, :handles, value_key)}"
          kept = i.gk_tags_current_tags.map(&:ref).join(' ')
          saved = write!(ctx, i, u, "#{kept} #{ref}")
          t = i.gk_tags_current_tags.detect { |x| x.type_id == type.id }
          resolved = GkTags.resolve("##{ref}")
          got = saved && t && resolved&.id == t.id ? "#{t.type.key} #{t.key}" : "saved #{saved} tag #{t&.key.inspect} resolved #{resolved&.key.inspect}"
          raise ::ActiveRecord::Rollback
        end
        want_type, want_value = Array(e['equals'])
        result("#{want_type} #{handle(s, want_value)}", got)
      end

      # A type (type:, inherit_parents as given) with a parent and a child tag (path: [parent key, child key]); the
      # issue (tg_hierarchy:) is tagged with the child only. equals: whether the filter Tagg on the parent lists the
      # issue for the person (as:). The path written parent/child resolves to the child as well.
      ::GkScenarios::Expect.register('tg_hierarchy') do |ctx, e|
        s = ctx.scenario
        u = user(ctx, e['as'])
        parent_key, child_key = Array(e['path'])
        got = nil
        ::GkTagsType.transaction do
          type = make_type(s, e['type'])
          parent = make_tag(s, parent_key, type)
          child = make_tag(s, child_key, type, parent)
          i = issue(ctx, e['tg_hierarchy']) or raise ::GkScenarios::Error, "tg_hierarchy #{e['key']}: no issue"
          GkTags::Tagging.apply(i, u, GkTags::Tagging.read(i.gk_tags_current_tags.map(&:ref).push(child.ref).join(' ')))
          path = "#{s.t(:tags, :handles, parent_key)}/#{s.t(:tags, :handles, child_key)}"
          got = "#{listed_with_tag?(ctx, u, parent, i)} #{GkTags.resolve(path)&.id == child.id}"
          raise ::ActiveRecord::Rollback
        end
        result("#{e['equals'] != false} true", got)
      end

      # A parent and a child (path:), then the parent moved under its child and the child under itself. equals: false,
      # both refused, nothing moved.
      ::GkScenarios::Expect.register('tg_cycle') do |ctx, e|
        s = ctx.scenario
        parent_key, child_key = Array(e['tg_cycle'])
        got = nil
        ::GkTagsTag.transaction do
          parent = make_tag(s, parent_key, nil)
          child = make_tag(s, child_key, nil, parent)
          a = GkTags::Lifecycle.move(parent, admin, child)
          b = GkTags::Lifecycle.move(child, admin, child)
          got = a || b || parent.reload.parent_id.present?
          raise ::ActiveRecord::Rollback
        end
        result(e['equals'] == true, got)
      end

      # People's object (kind: organization or person, tg_object_write: its key) tagged through its own save with
      # handles: as a person (as:). equals: the object's tags afterwards (handle keys); events: how many tag events
      # that wrote on the object (with records)
      ::GkScenarios::Expect.register('tg_object_write') do |ctx, e|
        s = ctx.scenario
        u = user(ctx, e['as'])
        feature_on!('tags.objects')
        got = nil
        ::GkTagsTag.transaction do
          obj = object_of(ctx, e.merge('kind' => e['kind'] || 'organization'), e['tg_object_write'])
          raise ::GkScenarios::Error, "tg_object_write #{e['key']}: no object" unless obj.respond_to?(:gk_tag_list=)

          last = defined?(::GkRecordsEvent) ? ::GkRecordsEvent.maximum(:id).to_i : 0
          saved = write!(ctx, obj, u, handles_text(s, e['handles']))
          got = saved ? obj.gk_tags_current_tags.map(&:key).sort.join(' ') : "refused: #{obj.errors.full_messages.join(' ')}"
          got += " events #{::GkRecordsEvent.where(kind: GkTags::OBJECT_KIND).where('id > ?', last).count}" if e.key?('events') && defined?(::GkRecordsEvent)
          raise ::ActiveRecord::Rollback
        end
        want = Array(e['equals']).map { |k| handle(s, k) }.sort.join(' ')
        want += " events #{e['events']}" if e.key?('events') && defined?(::GkRecordsEvent)
        result(want, got)
      end
    end
  end

  # gk_scenarios loads this file and calls this once every plugin is in; nothing else loads it
  def self.register_scenarios! = Scenarios.register!
end
