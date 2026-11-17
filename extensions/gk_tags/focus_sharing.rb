# frozen_string_literal: true

module GkTags
  # Who sees a person's personal markings of a kind that is shared by choice (GkTags::Personal, sharing :chosen; today
  # focus). The person shares the current markings and the history separately, per kind (personal:), each with the
  # manager, one or more groups (Redmine groups and people groups) and single users. FocusSharing is this for focus.
  # Defaults: the current focus to the manager, the history to nobody; they hold for everyone at once: a person with
  # no rows in gk_tags_focus_shares has them. Everyone sees their own; administrators follow the same rule. Sharing
  # and taking back are events on the person in records.
  # The manager: the people responsibility named in the setting manager_responsibility. The managers of a user: for
  # each people group the person is a member of (the whole organization when none), the holders of the responsibility
  # there (holders falls back to the whole organization) and the one who acts for it (holder, a deputy when the holder
  # is away). Without people or the setting: no manager.
  module Sharing
    SCOPES = %w[current history].freeze
    KINDS = %w[manager group people_group user].freeze
    NONE = 'none'
    DEFAULTS = { 'current' => [['manager', nil]], 'history' => [] }.freeze
    SHARED = 'tag_focus_shared'
    UNSHARED = 'tag_focus_unshared'
    EVENT_KINDS = [SHARED, UNSHARED].freeze

    module_function

    def ready?
      ::GkTagsFocusShare.table_exists?
    rescue StandardError
      false
    end

    def manager_key = GkTags.setting('manager_responsibility', '').to_s

    # { 'current' => [[kind, target_id], ...], 'history' => [...] }: the person's own rows, or the defaults
    def rows(user, personal: 'focus')
      return DEFAULTS.transform_values(&:dup) unless ready?

      list = ::GkTagsFocusShare.where(user_id: user.id, personal: personal.to_s).order(:id).to_a
      return DEFAULTS.transform_values(&:dup) if list.empty?

      SCOPES.index_with { |s| list.select { |r| r.scope == s && r.kind != NONE }.map { |r| [r.kind, r.target_id] }.uniq }
    end

    def defaults?(user, personal: 'focus') = !ready? || !::GkTagsFocusShare.exists?(user_id: user.id, personal: personal.to_s)

    # Only what can be shared: known kinds, a target for every kind but manager
    def clean(list)
      Array(list).filter_map do |kind, id|
        k = kind.to_s
        next nil unless KINDS.include?(k)
        next ['manager', nil] if k == 'manager'

        id.to_i.positive? ? [k, id.to_i] : nil
      end.uniq
    end

    # Saves the person's whole choice (both scopes) and writes an event for each recipient added or taken back.
    # Nothing shared at all is kept as a row of kind none, so that the person is not on the defaults again.
    def save(user, wanted, by: user, personal: 'focus')
      return false unless ready?

      before = rows(user, personal: personal)
      after = SCOPES.index_with { |s| clean(wanted[s] || wanted[s.to_sym]) }
      now = ::Time.current
      ::GkTagsFocusShare.transaction do
        ::GkTagsFocusShare.where(user_id: user.id, personal: personal.to_s).delete_all
        after.each { |s, list| list.each { |k, id| ::GkTagsFocusShare.create!(user_id: user.id, personal: personal.to_s, scope: s, kind: k, target_id: id, created_at: now) } }
        ::GkTagsFocusShare.create!(user_id: user.id, personal: personal.to_s, scope: 'current', kind: NONE, created_at: now) if after.values.all?(&:empty?)
        SCOPES.each do |s|
          (after[s] - before[s]).each { |k, id| event(user, SHARED, by, s, k, id, personal) }
          (before[s] - after[s]).each { |k, id| event(user, UNSHARED, by, s, k, id, personal) }
        end
      end
      true
    end

    def share(user, scope, kind, id = nil, personal: 'focus')
      want = rows(user, personal: personal)
      want[scope.to_s] = (want[scope.to_s] + [[kind.to_s, id]]).uniq
      save(user, want, personal: personal)
    end

    def unshare(user, scope, kind, id = nil, personal: 'focus')
      want = rows(user, personal: personal)
      want[scope.to_s] = want[scope.to_s].reject { |k, t| k == kind.to_s && (kind.to_s == 'manager' || t.to_i == id.to_i) }
      save(user, want, personal: personal)
    end

    # The event on the person: records' user target when there is one, else people's person target, else nothing
    # (a line in the log)
    def event(user, kind, by, scope, share_kind, target_id, personal = 'focus')
      return unless defined?(::GkRecords::Events) && ::GkRecords::Kinds.find(:event, kind)

      target = if ::GkRecords::Targets.find('user') then user
               elsif ::GkRecords::Targets.find('person') && defined?(::GkPeople) && ::GkPeople.respond_to?(:person_for) then ::GkPeople.person_for(user)
               end
      unless target && ::GkRecords::Targets.for_object(target)
        Rails.logger.info("[gk_tags] focus sharing of user #{user.id}: no user or person target in records, no event")
        return
      end
      details = { 'personal' => personal.to_s, 'scope' => scope, 'with' => share_kind }
      case share_kind
      when 'user' then details['recipient'] = defined?(::GkRecords::Ref) ? ::GkRecords::Ref.person(target_id) : target_id
      when 'group', 'people_group' then details[share_kind] = target_id
      end
      ::GkRecords::Events.write(target, kind, details: details, user: by)
    end

    # The users who are the manager of a user by the responsibility (key: the setting by default); never the user
    def managers_of(user, key: manager_key)
      return [] if key.blank? || !defined?(::GkPeople::Responsibilities) || !::GkPeople::Responsibilities.ready?
      return [] unless ::GkPeople::Responsibilities.find(key)

      person = ::GkPeople.person_for(user) or return []
      groups = defined?(::GkPeopleGroupMember) ? ::GkPeopleGroup.active.where(id: ::GkPeopleGroupMember.where(person_id: person.id).select(:group_id)).to_a : []
      ids = (groups.presence || [nil]).flat_map do |g|
        held = ::GkPeople::Responsibilities.holders(key, g).map { |a| a.person&.user_id }
        acting = ::GkPeople::Responsibilities.holder(key, g)[:user]&.id
        held + [acting]
      end
      ids.compact.uniq - [user.id]
    rescue StandardError => e
      Rails.logger.warn("[gk_tags] focus managers of user #{user.id}: #{e.class}: #{e.message}")
      []
    end

    def people_group_ids(viewer)
      return [] unless defined?(::GkPeople) && defined?(::GkPeopleGroupMember)

      person = ::GkPeople.person_for(viewer) or return []
      ::GkPeopleGroupMember.where(person_id: person.id).pluck(:group_id)
    rescue StandardError
      []
    end

    # Does the viewer see the owner's current focus or history: her own always; otherwise when it is shared with the
    # viewer directly, through a Redmine group or a people group the viewer is in, or the viewer is the owner's manager
    def sees?(owner, viewer, scope, key: manager_key, personal: 'focus')
      return false unless owner && viewer&.logged?
      return true if owner.id == viewer.id

      rows(owner, personal: personal)[scope.to_s].to_a.any? do |kind, id|
        case kind
        when 'user' then id == viewer.id
        when 'group' then viewer.group_ids.include?(id)
        when 'people_group' then people_group_ids(viewer).include?(id)
        when 'manager' then managers_of(owner, key: key).include?(viewer.id)
        else false
        end
      end
    end

    # The people whose current focus the viewer sees (the filter I fokus, any), herself included
    def visible_owner_ids(viewer = ::User.current, scope = 'current')
      ([viewer.id] + Focus.owner_ids.select { |id| (u = ::User.find_by(id: id)) && sees?(u, viewer, scope) }).uniq
    end

    # What the sharing box offers: Redmine groups, people groups and users the viewer may see, as [[name, id], ...]
    def choices(viewer = ::User.current)
      groups = ::Group.givable.active.sorted.map { |g| [g.name, g.id] }
      people = defined?(::GkPeopleGroup) ? ::GkPeopleGroup.active.sorted.map { |g| [g.name, g.id] } : []
      users = ::User.active.visible(viewer).where.not(id: viewer.id).sorted.limit(1000).map { |u| [u.name, u.id] }
      { 'group' => groups, 'people_group' => people, 'user' => users }
    rescue StandardError => e
      Rails.logger.warn("[gk_tags] focus sharing choices: #{e.class}: #{e.message}")
      { 'group' => [], 'people_group' => [], 'user' => [] }
    end
  end

  # Focus's sharing: Sharing with the kind focus, which is its default
  FocusSharing = Sharing

  # The focus button among the issue's actions: one row in gui_stuff's actions_menu whose label, tooltip, state and
  # address follow the issue. Off: Sätt fokus posts focus_add. On: I mitt fokus (drawn as a state that is on), a
  # click posts focus_remove. Off with the list full: the script shows the issues in focus and one click replaces one
  # of them. The issue and the state are worked out once per request (never written into the page hash, which
  # gui_stuff sends to the browser).
  class FocusCurrent < ::ActiveSupport::CurrentAttributes
    attribute :seen
  end

  module FocusButton
    module_function

    def memo(page, what)
      FocusCurrent.seen ||= {}
      FocusCurrent.seen[[page[:id].to_i, ::User.current.id, what]] ||= yield
    end

    def issue(page) = memo(page, :issue) { ::Issue.find_by(id: page[:id]) || false } || nil
    def shown?(page) = GkTags.ready? && GkTags.feature?('tags.focus') && (i = issue(page)) && GkTags::Access.personal?(i) ? true : false

    # :on, :full or :off
    def state(page)
      memo(page, :state) do
        user = ::User.current
        if Focus.in_focus?(issue(page), user) then :on
        elsif Focus.full?(user) then :full
        else :off
        end
      end
    end

    # With the list full the row asks which issue to replace in a surface of the upper layer, so it ends with "…"
    def label(page)
      case state(page)
      when :on then ::I18n.t(:button_gk_tags_in_focus)
      when :full then "#{::I18n.t(:button_gk_tags_focus_add)}…"
      else ::I18n.t(:button_gk_tags_focus_add)
      end
    end

    def title(page)
      case state(page)
      when :on then ::I18n.t(:text_gk_tags_focus_title_on, n: Focus.count(::User.current), max: Focus.max)
      when :full then ::I18n.t(:text_gk_tags_focus_title_full, max: Focus.max)
      else ::I18n.t(:text_gk_tags_focus_title_off, max: Focus.max)
      end
    end

    # The routes' own helpers carry the instance's root (config.relative_url_root), so nothing is put in front of them
    def href(page)
      h = Rails.application.routes.url_helpers
      state(page) == :on ? h.gk_tags_focus_remove_path(page[:id]) : h.gk_tags_focus_add_path(page[:id])
    end

    # What the script needs on the issue page (gui_stuff's PageData 'tg_focus'): the state, where to post, and the
    # issues now in focus to choose from when the list is full, with the texts
    def data(issue, user)
      h = Rails.application.routes.url_helpers
      state = if Focus.in_focus?(issue, user) then 'on' elsif Focus.full?(user) then 'full' else 'off' end
      items = Focus.items(user, user).map do |it|
        i = it[:issue]
        { id: it[:tagging].taggable_id, subject: i&.subject, priority: i&.priority&.name, due: i&.due_date && ::I18n.l(i.due_date) }
      end
      { state: state, issue: issue.id, max: Focus.max, add: h.gk_tags_focus_add_path(issue.id), items: items,
        t: { title: ::I18n.t(:button_gk_tags_focus_add), intro: ::I18n.t(:text_gk_tags_focus_choose, n: Focus.count(user)),
             due: ::I18n.t(:field_due_date), no_due: ::I18n.t(:text_gk_tags_no_due), hidden: ::I18n.t(:text_gk_tags_hidden_issue),
             replace: ::I18n.t(:button_gk_tags_focus_replace), cancel: ::I18n.t(:button_cancel) } }
    end
  end
end
