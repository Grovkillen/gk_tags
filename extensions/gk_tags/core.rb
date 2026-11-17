# frozen_string_literal: true

module GkTags
  # The first release: free and managed tags with their lifecycle, aliases, renaming and merging ("Livscykel, alias och
  # sammanslagning"); tagging issues through a tag field, with #tag in text shown as a link ("Bara taggfältet nu"); the
  # filter and column in the issue list; personal marks on issues and notes ("Ärenden och anteckningar"); the focus
  # list with its page ("Fokuslistan med sidan"). Types, hierarchy, more taggable objects, tags made from text, spaces,
  # behaviours and ghost pills come in later releases.
  KINDS = %w[tag mark focus].freeze
  STATUSES = %w[free established managed retired merged].freeze
  # The classes tags itself knows; other plugins add theirs with GkTags::Taggables.register
  TAGGABLE_TYPES = %w[Issue Journal].freeze
  # Colour in data is a category of the shared palette, never a hue: a type and a mark keep a category
  # 1 to 12, drawn with the roles --gk-role-category-<n> and -soft; a tag that means something urgent keeps a marking,
  # drawn with the roles of that alert level (--gk-role-alert-warning, --gk-role-alert-alarm)
  CATEGORIES = (1..12).to_a.freeze
  MARKINGS = %w[warning alarm].freeze
  # A handle: a letter first, then letters, digits, - _ and . (: and / are kept for types and paths, ### syntax)
  HANDLE = /\A\p{L}[\p{L}\p{N}_.\-]*\z/
  # A value after a namespace may start with a digit (#ReleaseNote:2.04)
  VALUE = /\A[\p{L}\p{N}][\p{L}\p{N}_.\-]*\z/
  OWN_TARGET = 'gk_tags_tag'
  # tag_typed and tag_moved (### types, ### hierarchy)
  OWN_KINDS = %w[tag_promoted tag_renamed tag_aliased tag_merged tag_retired tag_restored tag_typed tag_moved].freeze
  # A type's own events, and the tags of an object without a journal changed (an organization, a person)
  TYPE_TARGET = 'gk_tags_type'
  TYPE_KINDS = %w[type_created type_changed type_retired type_restored].freeze
  OBJECT_KIND = 'tag_object_tags'

  module_function

  # A category 1 to 12 and a marking as given in a form or a scenario; anything else is none
  def category(value) = CATEGORIES.include?(value.to_i) ? value.to_i : nil
  def marking(value) = MARKINGS.include?(value.to_s) ? value.to_s : nil

  # A page that is read, not edited (a tag's page, the lists of tags and types): names and descriptions as GK Fields
  # translates them. The plugin's controllers are off in fields, so that the forms edit them as written.
  def translated(&block)
    return yield unless defined?(::GkFields::Translations) && ::GkFields::Translations.respond_to?(:with)

    ::GkFields::Translations.with(true, &block)
  end

  # Never ready without GK GUI Stuff (GkTags.gui?, gate.rb): everything of tags that asks this stays off
  def ready?
    return false unless GkTags.gui?

    @ready ||= ::ActiveRecord::Base.connection.data_source_exists?('gk_tags_taggings')
  rescue StandardError
    false
  end

  # A declared function in records' register, asked at call time; off until switched on, off without records
  # ('tags.marks', 'tags.focus'), and off without GK GUI Stuff too (GkTags.gui?, gate.rb)
  def feature?(key) = GkTags.gui? && defined?(::GkRecords::Features) ? ::GkRecords::Features.on?(key) : false

  # An appearance setting in records' register, for the person (optional lets each person switch it off under My
  # account); off without records ('tags.sidebar', 'tags.note_text'), and off without GK GUI Stuff too
  NOTE_TEXT = 'tags.note_text'
  def appearance?(key, user = ::User.current) = GkTags.gui? && defined?(::GkRecords::AppearanceSettings) ? ::GkRecords::AppearanceSettings.on_for?(key, user) : false

  # A value of an appearance setting, its default without records
  def appearance_value(key, name, fallback) = (defined?(::GkRecords::AppearanceSettings) ? ::GkRecords::AppearanceSettings.value(key, name) : nil) || fallback

  def setting(key, default = nil)
    v = (::Setting.plugin_gk_tags || {})[key.to_s]
    v.nil? || v == '' ? default : v
  rescue StandardError
    default
  end

  def setting_i(key, default) = setting(key, default).to_i.then { |n| n.positive? ? n : default }

  # A handle as stored: without #, trimmed, lowercase (Unicode); nil when it is not a valid handle
  def normalize(text)
    h = text.to_s.strip.sub(/\A#/, '').unicode_normalize(:nfc).downcase
    return nil if h.empty? || h.length > 80 || h.length < setting_i('min_length', 2) || h !~ HANDLE

    h
  end

  # Handles out of a tag field: separated by spaces, commas or semicolons, each with or without #
  def split(text) = text.to_s.split(/[\s,;]+/).reject(&:empty?)

  # A tag field as text: the form's list of choices (its blank first) joined by spaces, or the text as written (REST
  # and scenarios)
  def list_text(value) = value.is_a?(Array) ? value.flatten.map(&:to_s).reject(&:blank?).join(' ') : value.to_s

  # The global tag a handle resolves to, by key or alias; a merged tag resolves to the one it was merged into.
  # Also ns:value and a path (resolve_ref); nil when it is unknown or ambiguous
  def resolve(handle)
    f = resolve_ref(handle)
    f.status == :ok ? f.tag : nil
  end

  def follow_merged(tag)
    n = 0
    tag = tag.merged_into while tag&.status == 'merged' && tag.merged_into && (n += 1) < 20
    tag
  end

  # A reference as written, "#ns:value", "#parent/child" or "#key", as [namespace or nil, [segments]] in stored
  # form; nil when it is not valid. A value after a namespace may start with a digit.
  def parse_ref(text)
    s = text.to_s.strip.sub(/\A#/, '').unicode_normalize(:nfc).downcase
    return nil if s.empty? || s.length > 250

    ns = nil
    if s.include?(':')
      ns, s = s.split(':', 2)
      return nil unless ns.length.between?(1, 40) && ns.match?(HANDLE)
    end
    segs = s.split('/', -1)
    min = setting_i('min_length', 2)
    re = ns ? VALUE : HANDLE
    return nil if segs.empty? || segs.any? { |g| g.empty? || g.length > 80 || g.length < min || !g.match?(re) }

    [ns, segs]
  end

  # What a written reference is (### syntax, ### hierarchy): status :ok with the tag, :new (an unknown plain key or
  # ns:value, which becomes a free tag of that type for whoever may create free tags), :ambiguous (the leaf is under
  # several parents: write the path), :unknown_path, :no_type (no type has the namespace) or :bad
  Found = Struct.new(:status, :tag, :key, :type)

  def resolve_ref(text)
    parsed = parse_ref(text) or return Found.new(:bad)
    ns, segs = parsed
    type = nil
    if ns
      type = Types.by_namespace(ns) or return Found.new(:no_type, nil, segs.last, nil)
    end
    ns_ids = Types.namespaced_ids
    cands = ::GkTagsTag.global.where(key: segs.last).to_a.select { |t| type ? t.type_id == type.id : !ns_ids.include?(t.type_id) }
    if segs.size > 1
      want = segs[0..-2].reverse
      cands = cands.select { |t| t.ancestors.map(&:key).first(want.size) == want }
    end
    if cands.empty? && ns.nil? && segs.size == 1
      a = ::GkTagsAlias.find_by(handle: segs.last)
      cands = [a.tag] if a&.tag
    end
    cands = cands.map { |t| follow_merged(t) }.compact.uniq(&:id)
    return Found.new(:ok, cands.first, cands.first.key, cands.first.type) if cands.size == 1
    return Found.new(:ambiguous, nil, segs.last, type) if cands.size > 1

    Found.new(segs.size > 1 ? :unknown_path : :new, nil, segs.last, type)
  end

  # A reference kept in an issue's history, read again now: [the tag it stands for today, or nil when no tag has it
  # any more; the merged tag it named, or nil when it named the tag itself]
  def resolve_kept(text)
    f = resolve_ref(text)
    return [nil, nil] unless f.status == :ok

    ns, segs = parse_ref(text)
    merged = ::GkTagsTag.global.where(key: segs.last, status: 'merged').to_a.find do |t|
      (ns.nil? || t.type&.namespace.to_s.downcase == ns) && follow_merged(t)&.id == f.tag.id
    end
    [f.tag, merged]
  end

  # Free tags anyone with the permission writes become established when enough people use them or they sit on
  # enough objects (settings establish_users, default 3, and establish_objects, default 10; Avgjorda frågor)
  def check_established(tag)
    return unless tag.status == 'free'

    t = tag.active_taggings
    users = t.distinct.count(:tagger_id)
    # Distinct pairs counted here: || joins text only on some databases and is "or" on MySQL
    objects = t.distinct.pluck(:taggable_type, :taggable_id).size
    return unless users >= setting_i('establish_users', 3) || objects >= setting_i('establish_objects', 10)

    tag.update!(status: 'established')
  end

  # Who may do what (plugins/tags ### admin, ### taggables, ### marks, ### focus)
  module Access
    module_function

    def on?(project) = GkTags.ready? && project&.module_enabled?(:gk_tags)

    def view?(issue, user = ::User.current) = issue.is_a?(::Issue) && on?(issue.project) && issue.visible?(user) && user.allowed_to?(:gk_tags_view, issue.project)
    def tag?(issue, user = ::User.current) = view?(issue, user) && user.allowed_to?(:gk_tags_tag, issue.project)
    # An object outside projects (an organization, a person) asks the permission in any project
    def create_free?(project, user = ::User.current)
      project ? user.allowed_to?(:gk_tags_create_free, project) : user.allowed_to?(:gk_tags_create_free, nil, global: true)
    end

    # Marks and focus are a person's own about herself: whoever sees the issue in a project with the module
    def personal?(issue, user = ::User.current) = user.logged? && issue.is_a?(::Issue) && on?(issue.project) && issue.visible?(user)

    def manage?(user = ::User.current) = user.admin?
  end

  # The lifecycle of a global tag (### tags, ### identity), each step an event on the tag in records with who, when
  # and the reason, so that nothing changes without a trace
  module Lifecycle
    module_function

    def event(tag, kind, user, details, reason = nil)
      return unless defined?(::GkRecords::Events)

      ::GkRecords::Events.write(tag, kind, details: details, reason: reason.presence, user: user)
    end

    # Managed: an administrator gives it a name, a description and a marking (warning, alarm or none: an empty string)
    def promote(tag, user, name: nil, description: nil, marking: nil, reason: nil)
      tag.assign_attributes(status: 'managed', promoted_at: ::Time.current, promoted_by_id: user.id)
      tag.name = name if name
      tag.description = description if description
      tag.marking = marking.presence if marking
      return false unless tag.save

      event(tag, 'tag_promoted', user, { 'name' => tag.name, 'marking' => tag.marking }, reason)
      true
    end

    # A new handle; the old one becomes an alias (former_key), so text where it is written still resolves
    def rename(tag, user, new_key, reason: nil)
      k = GkTags.normalize(new_key)
      unless k
        tag.errors.add(:key, :invalid)
        return false
      end
      old = tag.key
      return true if k == old

      ::GkTagsTag.transaction do
        tag.key = k
        raise ::ActiveRecord::Rollback unless tag.save

        ::GkTagsAlias.create!(tag_id: tag.id, handle: old, former_key: true, created_by_id: user.id, created_at: ::Time.current)
        event(tag, 'tag_renamed', user, { 'key' => [old, k] }, reason)
      end
      tag.errors.empty? && tag.key == k
    end

    def add_alias(tag, user, handle, language: nil, reason: nil)
      h = GkTags.normalize(handle) or return [false, [::I18n.t(:error_gk_tags_handle)]]
      a = ::GkTagsAlias.new(tag_id: tag.id, handle: h, language: language.presence, created_by_id: user.id, created_at: ::Time.current)
      return [false, a.errors.full_messages] unless a.save

      event(tag, 'tag_aliased', user, { 'alias' => h, 'language' => a.language }, reason)
      [true, []]
    end

    # Merge source into target: the source keeps every tagging and its history and works as an alias of the target
    # (filters and the tag field resolve it to the target); its own aliases follow it
    def merge(source, target, user, reason: nil)
      return [false, [::I18n.t(:error_gk_tags_merge_self)]] if source.id == target.id || target.status == 'merged'

      ::GkTagsTag.transaction do
        source.update!(status: 'merged', merged_into_id: target.id)
        ::GkTagsTag.where(merged_into_id: source.id).update_all(merged_into_id: target.id)
        event(source, 'tag_merged', user, { 'into' => target.key }, reason)
      end
      [true, []]
    end

    # Retired: hidden from suggestions, nothing breaks (### tags); restore makes it managed again if it was promoted
    def retire(tag, user, reason: nil)
      tag.update!(status: 'retired')
      event(tag, 'tag_retired', user, {}, reason)
    end

    def restore(tag, user, reason: nil)
      tag.update!(status: tag.promoted_at ? 'managed' : 'free')
      event(tag, 'tag_restored', user, { 'status' => tag.status }, reason)
    end

    # Another type, or none (the tag then follows the type free); a retired type is not given
    def set_type(tag, user, type, reason: nil)
      old = tag.type
      return true if old&.id == type&.id

      if type && !type.active
        tag.errors.add(:base, ::I18n.t(:error_gk_tags_type_retired, type: type.name))
        return false
      end
      tag.type = type
      return false unless tag.save

      event(tag, 'tag_typed', user, { 'type' => [old&.key, type&.key] }, reason)
      true
    end

    # Another parent, or none; never a cycle (the tag refuses it). The old and new paths are in the event.
    def move(tag, user, parent, reason: nil)
      old = tag.parent
      return true if old&.id == parent&.id

      before = old&.path_key
      tag.parent = parent
      return false unless tag.save

      event(tag, 'tag_moved', user, { 'parent' => [before, parent&.path_key] }, reason)
      true
    end
  end

  # A type is made, changed, retired and restored by an administrator, each an event on the type in records with
  # the reason. A type is never deleted.
  module TypeLifecycle
    module_function

    def event(type, kind, user, details, reason = nil)
      return unless defined?(::GkRecords::Events)

      ::GkRecords::Events.write(type, kind, details: details, reason: reason.presence, user: user)
    end

    def save(type, user, attrs, reason: nil)
      created = type.new_record?
      type.assign_attributes(attrs)
      return false unless type.save

      changes = type.saved_changes.except('id', 'created_at', 'updated_at')
      return true if changes.empty?

      details = created ? changes.transform_values(&:last).compact : changes.transform_values { |(a, b)| [a, b] }
      event(type, created ? 'type_created' : 'type_changed', user, details, reason)
      true
    end

    def retire(type, user, reason: nil)
      return true unless type.active

      type.update!(active: false)
      event(type, 'type_retired', user, {}, reason)
      true
    end

    def restore(type, user)
      return true if type.active

      type.update!(active: true)
      event(type, 'type_restored', user, {})
      true
    end
  end
end
