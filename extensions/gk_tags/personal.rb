# frozen_string_literal: true

module GkTags
  # Marks: the personal marking of kind mark (GkTags::Personal), on issues and notes, with a mark note seen only by
  # the owner. Every person has a default mark ("Highlight", made the first time) and may make more with a category of
  # their own and share one (others who see the object see that it is marked with it, never the note). Nothing is
  # mailed, nothing is counted per person. What is the same for every kind is in Personal; what is the marks' own is
  # here: the default mark, making a mark and the list Mina märken.
  module Marks
    module_function

    def kind = Personal.find(:mark)

    def default_for(user)
      ::GkTagsTag.find_by(kind: 'mark', owner_id: user.id, key: 'highlight') ||
        ::GkTagsTag.create!(kind: 'mark', owner_id: user.id, key: 'highlight', name: ::I18n.t(:label_gk_tags_highlight), category: 10,
                           status: 'managed', created_by_id: user.id)
    end

    def of(user) = Personal.tags_of(kind, user)

    # A new mark of one's own: the key is made from the name (### identity rules), unique among one's own marks
    def create(user, name, category: nil, shared: false)
      base = GkTags.normalize(name.to_s.tr(' ', '-')) || 'mark'
      key = base
      n = 1
      key = "#{base}-#{n += 1}" while ::GkTagsTag.exists?(kind: 'mark', owner_id: user.id, key: key)
      ::GkTagsTag.create(kind: 'mark', owner_id: user.id, key: key, name: name.to_s.strip.first(255).presence || key,
                        category: GkTags.category(category), shared: shared == true, status: 'managed', created_by_id: user.id)
    end

    # Mark an issue or a note with one of one's own marks (the default when none is given), with an optional mark note
    def mark(object, user, mark = nil, note: nil)
      mark ||= default_for(user)
      return nil unless mark.kind == 'mark'

      Personal.put(mark, object, user, note: note)
    end

    # The marks on an object the viewer may see: her own (with the note) and others' shared ones (without it)
    def on(object, viewer = ::User.current) = Personal.on(object, viewer, kinds: [kind])

    # Mina märken: the person's own marked objects she may still see, newest first; only the shared ones when someone
    # else looks at them
    def listing(owner, viewer = ::User.current, mark_id: nil)
      scope = ::GkTagsTagging.active.includes(:tag).joins(:tag).where(gk_tags_tags: { kind: 'mark', owner_id: owner.id })
      scope = scope.where(gk_tags_tags: { shared: true }) unless owner == viewer
      scope = scope.where(tag_id: mark_id) if mark_id.present?
      scope.order(created_at: :desc).limit(500).to_a.select { |t| (i = t.issue) && i.visible?(viewer) }
    end
  end

  # Focus: the personal marking of kind focus (GkTags::Personal): at most focus_max (default 3) issues a person is
  # working on now, set by oneself only, in the order of the issue's priority (highest first) and due date (earliest
  # first, none last). When the list is full the issue to replace is named (replace: its id) and replaced in the same
  # step. Every add, remove, replace and undo is an event on the issue in records (the kind's events). Who sees a
  # person's focus is the kind's sharing (GkTags::Sharing, through FocusSharing).
  module Focus
    ADDED = 'tag_focus_added'
    REMOVED = 'tag_focus_removed'
    EVENT_KINDS = [ADDED, REMOVED].freeze

    module_function

    def kind = Personal.find(:focus)
    def max = kind.cap_value
    def tag_for(user) = Personal.tag_for(kind, user)
    def taggings(user) = Personal.taggings(kind, user)
    def list(user) = Personal.sorted(kind, taggings(user))

    def in_focus?(issue, user) = taggings(user).any? { |t| t.taggable_id == issue.id }
    def count(user) = Personal.count(kind, user)
    def full?(user) = Personal.full?(kind, user)

    # [:added | :replaced | :already | :full | :not_allowed, the id of the issue replaced or nil]; never allowed
    # without GK GUI Stuff (Access.personal? asks GkTags.ready?, which asks the gate)
    def add(issue, user, replace: nil)
      return [:not_allowed, nil] unless GkTags::Access.personal?(issue, user)

      items = taggings(user)
      return [:already, nil] if items.any? { |t| t.taggable_id == issue.id }

      old = nil
      if items.size >= max
        old = replace.present? ? items.detect { |t| t.taggable_id == replace.to_i } : nil
        return [:full, nil] unless old
      end
      ::GkTagsTagging.transaction do
        Personal.remove(old, user, 'replaced_by' => issue.id) if old
        Personal.put(tag_for(user), issue, user, details: old ? { 'replacing' => old.taggable_id } : {})
      end
      [old ? :replaced : :added, old&.taggable_id]
    end

    def remove(issue, user)
      t = taggings(user).detect { |x| x.taggable_id == issue.id } or return false
      ::GkTagsTagging.transaction { Personal.remove(t, user) }
      true
    end

    # Ångra: takes out the issue that was put in (drop) and puts back the one that was taken out (restore), as the
    # notice after an add, a replace or a remove offers it. Only one's own focus; an issue that may no longer be
    # focused, or that would not fit, is not put back. true when anything changed.
    def undo(user, drop: nil, restore: nil)
      changed = false
      ::GkTagsTagging.transaction do
        if drop.present? && (t = taggings(user).detect { |x| x.taggable_id == drop.to_i })
          Personal.remove(t, user, 'undo' => true)
          changed = true
        end
        back = restore.present? ? ::Issue.find_by(id: restore.to_i) : nil
        if back && GkTags::Access.personal?(back, user) && !in_focus?(back, user) && count(user) < max
          Personal.put(tag_for(user), back, user, details: { 'undo' => true })
          changed = true
        end
      end
      changed
    end

    # Waiting: the status is one of the waiting statuses (setting), or the issue is assigned to someone else
    def waiting?(issue, owner)
      ids = Array(GkTags.setting('waiting_status_ids', [])).map(&:to_i)
      ids.include?(issue.status_id) || (issue.assigned_to_id && issue.assigned_to_id != owner.id && !(issue.assigned_to.is_a?(::Group) && issue.assigned_to.users.include?(owner)))
    end

    # The people with a focus list (an active focus tagging), as ids
    def owner_ids
      tag_ids = ::GkTagsTagging.active.where(taggable_type: 'Issue').joins(:tag).where(gk_tags_tags: { kind: 'focus' }).distinct.pluck(:tag_id)
      ::GkTagsTag.where(id: tag_ids).pluck(:owner_id).compact.uniq
    end

    # A person's current focus as the viewer may see it: [{ tagging:, issue: or nil (hidden) }]
    def items(owner, viewer = ::User.current)
      list(owner).map { |t| { tagging: t, issue: (i = ::Issue.find_by(id: t.taggable_id)) && i.visible?(viewer) ? i : nil } }
    end

    # Fokus i min grupp: every other person whose current focus is shared with the viewer (in a project: its
    # members), with whether the history is shared too; [{ user:, items:, history: bool }], persons by name
    def board(viewer = ::User.current, project: nil)
      users = ::User.active.where(id: owner_ids - [viewer.id])
      users = users.where(id: project.users.select(:id)) if project
      users.sorted.to_a.select { |u| FocusSharing.sees?(u, viewer, 'current') }.map do |u|
        { user: u, items: items(u, viewer), history: FocusSharing.sees?(u, viewer, 'history') }
      end.reject { |row| row[:items].empty? }
    end
  end


  # Tidigare fokus: read from the focus events in records and from the taggings of the person's focus tag (created_at
  # as added, removed_at as removed), so that nothing from before the events is lost; merged and deduplicated by
  # issue and time. Two modes: the last N issues (focus_history_issues, default 10) or the last N days
  # (focus_history_days, default 30).
  module FocusHistory
    Row = Struct.new(:issue_id, :from, :to, keyword_init: true)
    MODES = %w[issues days].freeze
    SAME = 120 # seconds: an event and a tagging this close for the same issue are the same time in focus

    module_function

    def default_n(mode) = mode.to_s == 'days' ? GkTags.setting_i('focus_history_days', 30) : GkTags.setting_i('focus_history_issues', 10)

    # Newest first: still in focus, then by when it left focus, then by when it came in
    def rows(user, mode: 'issues', n: nil)
      mode = MODES.include?(mode.to_s) ? mode.to_s : 'issues'
      n = n.to_i.positive? ? n.to_i : default_n(mode)
      now = ::Time.current
      all = merged(user).sort_by { |r| [-(r.to || now).to_f, -r.from.to_f] }
      if mode == 'days'
        since = now - n.days
        all.select { |r| r.to.nil? || r.to >= since }
      else
        keep = all.map(&:issue_id).uniq.first(n)
        all.select { |r| keep.include?(r.issue_id) }
      end
    end

    def merged(user)
      events = from_events(user)
      used = {}
      legacy = from_taggings(user).reject do |l|
        e = events.select { |x| !used[x.object_id] && x.issue_id == l.issue_id && (x.from - l.from).abs <= SAME }.min_by { |x| (x.from - l.from).abs }
        next false unless e

        used[e.object_id] = true
        e.to ||= l.to
        true
      end
      events + legacy
    end

    def from_taggings(user)
      tag = ::GkTagsTag.find_by(kind: 'focus', owner_id: user.id) or return []
      ::GkTagsTagging.where(tag_id: tag.id, taggable_type: 'Issue').order(:created_at).map do |t|
        Row.new(issue_id: t.taggable_id, from: t.created_at, to: t.removed_at)
      end
    end

    # The person's own focus events (only the person puts in and takes out her own focus), paired per issue
    def from_events(user)
      return [] unless defined?(::GkRecordsEvent)

      open = {}
      out = []
      ::GkRecordsEvent.where(target_type: 'issue', kind: Focus::EVENT_KINDS, user_id: user.id).order(:created_at, :id).each do |ev|
        id = ev.target_id
        if ev.kind == Focus::ADDED
          next if open[id]

          open[id] = Row.new(issue_id: id, from: ev.created_at, to: nil)
          out << open[id]
        elsif open[id]
          open[id].to = ev.created_at
          open.delete(id)
        end
      end
      out
    rescue StandardError => e
      Rails.logger.warn("[gk_tags] focus history from events: #{e.class}: #{e.message}")
      []
    end
  end
end
