# frozen_string_literal: true

module GkTags
  # Personal markings: one mechanism for everything a person puts on things for herself, marks and focus being two
  # kinds of it. A kind is a row in this register, not code of its own: a personal tag (gk_tags_tags with owner_id and
  # the kind as kind) put on an object by a tagging (gk_tags_taggings: who, when, taken off when and by whom, a note).
  # What a kind may do is read from its row:
  # * one_per_person: the person has one tag of the kind, made by the register (focus); else as many as she makes,
  #   each with a name and a category (marks)
  # * notes: :many, a note per marking, the same tag several times with different notes (marks); :none
  # * cap: how many objects at most (a number, or a lambda reading a setting), nil for no cap
  # * order: :priority_due (the issue's priority, then due date) or :newest
  # * history: the person's earlier markings are kept to be shown (focus's Tidigare fokus)
  # * sharing: :none (only the owner), :everyone (a tag marked shared is seen by whoever sees the object, never the
  #   note) or :chosen (the owner shares it with her manager, groups and users, the current markings and the history
  #   apart: GkTags::Sharing)
  # * events: { added:, removed: } event kinds on the object in records, or nil
  # * surface: where it is put and shown: :pills (a pill per marking in the issue's head, put through the add icon's
  #   dialog), :button (a button among the issue's actions, its own code: focus)
  # * feature: the declared function in records that switches the kind on (nil: always)
  # Another plugin adds a kind with GkTags::Personal.register in an after_initialize.
  module Personal
    Kind = Struct.new(:key, :label, :plugin, :one_per_person, :notes, :cap, :order, :history, :sharing, :events, :surface, :feature,
                      keyword_init: true) do
      def on? = GkTags.ready? && (feature.nil? || GkTags.feature?(feature))
      def notes? = notes == :many
      def cap_value = cap.respond_to?(:call) ? cap.call : cap
      def surface?(where) = Array(surface).include?(where)
    end

    module_function

    def registry = (@registry ||= {})

    def register(key, label:, plugin: :gk_tags, one_per_person: false, notes: :none, cap: nil, order: :newest, history: false,
                 sharing: :none, events: nil, surface: [], feature: nil)
      registry[key.to_s] = Kind.new(key: key.to_s, label: label, plugin: plugin, one_per_person: one_per_person, notes: notes, cap: cap,
                                    order: order, history: history, sharing: sharing, events: events, surface: Array(surface), feature: feature)
    end

    def find(key) = registry[key.to_s]
    def all = registry.values
    def keys = registry.keys
    def of_tag(tag) = tag && find(tag.kind)
    def with_surface(where) = all.select { |k| k.on? && k.surface?(where) }

    # The person's tags of the kind that can be put: her own (not retired) for a kind with many, the one tag otherwise
    def tags_of(kind, user)
      return [tag_for(kind, user)] if kind.one_per_person

      ::GkTagsTag.where(kind: kind.key, owner_id: user.id).where.not(status: 'retired').order(:key).to_a
    end

    # The one tag of a one_per_person kind, made the first time
    def tag_for(kind, user)
      ::GkTagsTag.find_by(kind: kind.key, owner_id: user.id) ||
        ::GkTagsTag.create!(kind: kind.key, owner_id: user.id, key: kind.key, name: ::I18n.t(kind.label), status: 'managed', created_by_id: user.id)
    end

    def type_of(object) = object.class.base_class.name
    def issue_of(object) = object.is_a?(::Journal) ? object.journalized : object

    # The person's active markings of the kind (on issues unless another type is given)
    def taggings(kind, user, taggable_type: 'Issue')
      ids = ::GkTagsTag.where(kind: kind.key, owner_id: user.id).pluck(:id)
      return [] if ids.empty?

      ::GkTagsTagging.active.where(tag_id: ids, taggable_type: taggable_type).to_a
    end

    def count(kind, user) = taggings(kind, user).size
    def full?(kind, user) = (c = kind.cap_value) ? count(kind, user) >= c : false

    # The markings in the kind's order
    def sorted(kind, items)
      return items.sort_by { |t| [-t.created_at.to_f, -t.id] } unless kind.order == :priority_due

      issues = ::Issue.where(id: items.map(&:taggable_id)).includes(:priority).index_by(&:id)
      items.sort_by do |t|
        i = issues[t.taggable_id]
        [-(i&.priority&.position || 0), i&.due_date ? 0 : 1, i&.due_date || ::Date.new(9999, 1, 1), t.created_at]
      end
    end

    # Put one of the person's tags of a kind on an object (an issue or a note). A kind with notes may sit several times
    # with a note of its own each; a note never overwrites another, the same note twice is one, and without a note
    # nothing is added when the tag is there already (a note goes to the marking that has none). A kind without notes
    # sits once. The cap is the caller's (focus names what to replace). The marking, or nil when it may not be put.
    def put(tag, object, user, note: nil, details: {})
      kind = of_tag(tag)
      issue = issue_of(object)
      return nil unless kind && tag.owner_id == user.id && issue.is_a?(::Issue) && GkTags::Access.personal?(issue, user)

      text = kind.notes? ? note.to_s.strip.presence : nil
      same = ::GkTagsTagging.active.where(tag_id: tag.id, taggable_type: type_of(object), taggable_id: object.id).order(:id).to_a
      return same.first if same.any? && (text.nil? || same.any? { |t| t.note == text })

      bare = text && same.detect { |t| t.note.blank? }
      return bare.tap { |t| t.update!(note: text) } if bare

      t = ::GkTagsTagging.create!(tag_id: tag.id, taggable_type: type_of(object), taggable_id: object.id, project_id: issue.project_id,
                                  tagger_id: user.id, source: 'manual', note: text, created_at: ::Time.current)
      event(kind, issue, :added, user, details)
      t
    end

    def remove(tagging, user, details = {})
      kind = of_tag(tagging.tag)
      tagging.remove!(user)
      event(kind, issue_of(tagging.taggable), :removed, user, details) if kind
      true
    end

    # A new note on the person's own active marking of a kind with notes; an empty text takes the note away. The rule
    # of put holds: two markings of the same tag on the same object never have the same note (or both none), so such
    # a change is refused. No event, as putting a note is none. [true, nil], or [false, :gone] (not hers, not active,
    # no notes) or [false, :same] (the clash) or [false, :same_bare] (the clash, both without a note)
    def renote(tagging, user, note)
      kind = of_tag(tagging.tag)
      return [false, :gone] unless kind&.notes? && tagging.tag.owner_id == user.id && tagging.removed_at.nil?

      text = note.to_s.strip.presence
      return [true, nil] if text == tagging.note.presence

      others = ::GkTagsTagging.active.where(tag_id: tagging.tag_id, taggable_type: tagging.taggable_type, taggable_id: tagging.taggable_id)
                              .where.not(id: tagging.id)
      return [false, text ? :same : :same_bare] if others.any? { |t| t.note.presence == text }

      tagging.update!(note: text)
      [true, nil]
    end

    # The markings on an object the viewer may see, of the kinds given (the kinds drawn as pills by default): her own,
    # with their notes; someone else's when the kind lets her see it (a shared mark; a kind shared with her)
    def on(object, viewer = ::User.current, kinds: with_surface(:pills))
      keys = kinds.map(&:key)
      return [] if keys.empty?

      ::GkTagsTagging.active.includes(:tag).joins(:tag).where(taggable_type: type_of(object), taggable_id: object.id, gk_tags_tags: { kind: keys })
                    .order(:id).to_a.select { |t| sees?(t.tag, viewer) }
    end

    # May the viewer see markings with this tag: always her own; a shared tag of a kind shared with everyone; a tag of a
    # kind shared by choice when its owner shares the current markings with her
    def sees?(tag, viewer, scope = 'current')
      return true if tag.owner_id == viewer&.id

      case of_tag(tag)&.sharing
      when :everyone then tag.shared
      when :chosen then (owner = tag.owner) ? Sharing.sees?(owner, viewer, scope, personal: tag.kind) : false
      else false
      end
    end

    # The event on the issue in records with the person as a reference (never her name); nothing for a kind without
    # events, without records or without the issue as a records target
    def event(kind, issue_or_id, which, user, details)
      name = kind&.events && kind.events[which]
      return unless name && defined?(::GkRecords::Events) && ::GkRecords::Kinds.find(:event, name)

      issue = issue_or_id.is_a?(::Issue) ? issue_or_id : ::Issue.find_by(id: issue_or_id)
      return unless issue && ::GkRecords::Targets.for_object(issue)

      who = defined?(::GkRecords::Ref) ? ::GkRecords::Ref.person(user) : user.id
      ::GkRecords::Events.write(issue, name, details: { 'user' => who }.merge(details), user: user, project: issue.project)
    end
  end

  # tags' own two kinds
  Personal.register(:mark, label: :label_gk_tags_marks, one_per_person: false, notes: :many, order: :newest,
                           sharing: :everyone, surface: :pills, feature: 'tags.marks')
  Personal.register(:focus, label: :label_gk_tags_focus, one_per_person: true, notes: :none, cap: -> { GkTags.setting_i('focus_max', 3) },
                            order: :priority_due, history: true, sharing: :chosen,
                            events: { added: 'tag_focus_added', removed: 'tag_focus_removed' }, surface: :button, feature: 'tags.focus')
end
