# frozen_string_literal: true

module GkTags
  # The types are rows in gk_tags_types, seeded when the table has no rows (also after a scenario has emptied every
  # table). A tag without a type follows the type free.
  module Types
    module_function

    def ready?
      @ready ||= ::ActiveRecord::Base.connection.data_source_exists?('gk_tags_types')
    rescue StandardError
      false
    end

    def all
      return [] unless ready?

      ::GkTagsType.ensure_seeded!
      ::GkTagsType.sorted.to_a
    end

    def active = all.select(&:active)
    def free
      return nil unless ready?

      ::GkTagsType.find_by(key: ::GkTagsType::FREE) || (all && ::GkTagsType.find_by(key: ::GkTagsType::FREE))
    end
    def find(ref) = ready? && ref.present? ? (::GkTagsType.find_by(key: ref.to_s) || (ref.to_s.match?(/\A\d+\z/) ? ::GkTagsType.find_by(id: ref.to_i) : nil)) : nil

    # The type whose qualifier is ns, retired or not (text written with it still resolves; a retired type gets no new
    # tags)
    def by_namespace(ns) = ready? && ns.present? ? ::GkTagsType.find_by(namespace: ns.to_s.downcase) : nil
    def namespaced_ids = ready? ? ::GkTagsType.where.not(namespace: [nil, '']).pluck(:id) : []

    # { type_id => inherit_parents }, with nil (no type) as the type free; true when nothing says otherwise
    def inherit_map
      return Hash.new(true) unless ready?

      m = ::GkTagsType.pluck(:id, :inherit_parents).to_h
      m[nil] = free ? free.inherit_parents : true
      m
    end
  end

  # An object is tagged with the leaf only; a search on a tag also finds the objects tagged with its descendants,
  # walked down as long as each child's type inherits.
  module Hierarchy
    module_function

    # The tag ids a search on these tags finds: each tag and the tags merged into it, and the descendants (and the
    # tags merged into them) whose type inherits
    def search_ids(tags)
      tags = Array(tags).compact
      ids = tags.flat_map(&:self_and_merged_ids)
      inherit = Types.inherit_map
      frontier = tags.map(&:id)
      seen = frontier.to_h { |i| [i, true] }
      ::GkTagsTag::MAX_DEPTH.times do
        kids = ::GkTagsTag.global.where(parent_id: frontier).pluck(:id, :type_id)
        kids = kids.reject { |i, _| seen[i] }.select { |_, tid| inherit.key?(tid) ? inherit[tid] : inherit[nil] }
        break if kids.empty?

        frontier = kids.map(&:first)
        frontier.each { |i| seen[i] = true }
        ids += frontier + ::GkTagsTag.where(merged_into_id: frontier).pluck(:id)
      end
      ids.uniq
    end
  end

  # A plugin registers a class it owns with a key (the word allowed_on and required_for use), a label, who may see and
  # who may change an object's tags, and its address. tags includes GkTags::Taggable in the class: the attribute
  # gk_tag_list (the form and REST of the owner set it), the same reading and rules as the issue's tag field when it
  # is saved, and the tags written as one event on the object in records.
  # Issues are registered by tags itself (key issue) and keep their own patch and journal line.
  # The other objects follow the declared function tags.objects: off, their tags are not shown or written, and the
  # data stays.
  module Taggables
    Entry = Struct.new(:key, :class_name, :label, :view, :tag, :url, :title, :controllers, keyword_init: true) do
      def label_text = label.respond_to?(:call) ? label.call.to_s : ::I18n.t(label, default: key.to_s)
    end

    module_function

    def all = (@all ||= {})

    # controllers: the owner's controllers whose pages render tags' partials (gk_tags_tags/object_tags and
    # object_field); they get tags' helper. Nothing is registered without GK GUI Stuff (GkTags.gui?, gate.rb): the
    # answer is nil and the class is left as it is.
    def register(class_name, key:, label:, view:, tag:, url:, title: nil, controllers: [])
      return nil unless GkTags.gui?

      e = Entry.new(key: key.to_s, class_name: class_name.to_s, label: label, view: view, tag: tag, url: url, title: title || ->(o) { o.to_s },
                    controllers: Array(controllers).map(&:to_s))
      all[e.key] = e
      attach(e)
      e
    end

    def find(key) = all[key.to_s]
    def keys = all.keys
    def others = all.values.reject { |e| e.key == 'issue' }

    def for_object(obj)
      return nil if obj.nil?

      name = obj.class.respond_to?(:base_class) ? obj.class.base_class.name : obj.class.name
      all.values.detect { |e| e.class_name == name }
    end

    def key_for(obj) = for_object(obj)&.key
    def type_names = (GkTags::TAGGABLE_TYPES + all.values.map(&:class_name)).uniq

    # The other objects' tags are a declared function (tags.objects); issues follow their project module
    def on?(entry) = entry && (entry.key == 'issue' || GkTags.feature?('tags.objects'))
    def view?(obj, user = ::User.current) = (e = for_object(obj)) && on?(e) && GkTags.ready? && !!e.view.call(obj, user)
    def tag?(obj, user = ::User.current) = (e = for_object(obj)) && on?(e) && GkTags.ready? && !!e.tag.call(obj, user)

    def attach(entry)
      return if entry.key == 'issue' || !GkTags.gui?

      klass = entry.class_name.safe_constantize or return
      klass.include(GkTags::Taggable) unless klass < GkTags::Taggable
      # the registered controllers' views need no helper of their own: GkTagsHelper is in ActionView::Base, which every
      # view class inherits from (Patches.apply!)
    rescue StandardError => e
      Rails.logger.warn("[gk_tags] taggable #{entry.class_name}: #{e.class}: #{e.message}")
    end

    def attach_all! = all.each_value { |e| attach(e) }
  end

  def self.register(class_name, **opts) = Taggables.register(class_name, **opts)

  # Reading a tag field, checking it against the types' rules and setting an object's tags (shared by the issue's
  # patch, GkTags::Taggable and scenarios)
  module Tagging
    # written: as written; status, tag, key, type: GkTags.resolve_ref's answer
    Want = Struct.new(:written, :status, :tag, :key, :type)

    module_function

    def read(text) = GkTags.split(text).map { |w| f = GkTags.resolve_ref(w); Want.new(w, f.status, f.tag, f.key, f.type) }

    def type_name(obj) = obj.class.base_class.name
    def project_of(obj) = obj.respond_to?(:project) ? obj.project : nil

    # The object's tags now: [tag], a merged one shown as the tag it was merged into; laid on it already by preload
    def tags_of(obj)
      return [] unless GkTags.ready? && obj&.id

      pre = obj.instance_variable_get(:@gk_tags_preloaded)
      return pre if pre

      ids = ::GkTagsTagging.active.where(taggable_type: type_name(obj), taggable_id: obj.id).joins(:tag).where(gk_tags_tags: { kind: 'tag' }).pluck(:tag_id)
      ::GkTagsTag.where(id: ids).map { |t| GkTags.follow_merged(t) }.uniq.sort_by(&:key)
    end

    # The tags of many objects of one class at once, { id => [tag] }, in two queries with their types and parents (VAL
    # O-10: the issue list's column asked two per row)
    def tags_by_object(tname, ids)
      pairs = ::GkTagsTagging.active.where(taggable_type: tname, taggable_id: ids).joins(:tag).where(gk_tags_tags: { kind: 'tag' }).pluck(:taggable_id, :tag_id)
      tags = ::GkTagsTag.where(id: pairs.map(&:last).uniq).includes(:type, :parent, :merged_into).index_by(&:id)
      pairs.group_by(&:first).transform_values { |list| list.filter_map { |_, t| GkTags.follow_merged(tags[t]) }.uniq.sort_by(&:key) }
    end

    # Lays the tags of the objects (one class) on each of them, so that tags_of asks nothing more for them; a save
    # that sets the tags takes it away again
    def preload(objs)
      list = Array(objs).select { |o| o&.id }
      return if list.empty? || !GkTags.ready?

      map = tags_by_object(type_name(list.first), list.map(&:id))
      list.each { |o| o.instance_variable_set(:@gk_tags_preloaded, map[o.id] || []) }
    end

    # How a wanted tag is written in the journal and the event
    def ref_of(w)
      return w.tag.ref if w.tag

      w.type&.namespaced? ? "#{w.type.namespace}:#{w.key}" : w.key.to_s
    end

    # The type whose rules a wanted tag follows
    def type_of(w) = w.tag ? w.tag.rule_type : (w.type || Types.free)

    # The messages that refuse the list for the object (taggable key), or [] (### syntax, ### types: exclusive,
    # allowed_on, required_for). required_for holds where the tags are written: the issue form and REST with
    # gk_tag_list, the forms of the registered objects.
    def check(obj, wanted, user = ::User.current, key: Taggables.key_for(obj))
      errs = []
      project = project_of(obj)
      wanted.each do |w|
        case w.status
        when :bad then errs << ::I18n.t(:error_gk_tags_bad_handle, handle: w.written)
        when :no_type then errs << ::I18n.t(:error_gk_tags_no_namespace, handle: w.written)
        when :ambiguous then errs << ::I18n.t(:error_gk_tags_ambiguous, handle: w.written.sub(/\A#/, ''))
        when :unknown_path then errs << ::I18n.t(:error_gk_tags_no_such, handle: w.written.sub(/\A#/, ''))
        when :new
          if w.type && !w.type.active
            errs << ::I18n.t(:error_gk_tags_type_retired, type: w.type.name)
          elsif !GkTags::Access.create_free?(project, user)
            errs << ::I18n.t(:error_gk_tags_unknown, handle: ref_of(w))
          end
        end
      end
      typed = wanted.select { |w| %i[ok new].include?(w.status) }.map { |w| [w, type_of(w)] }
      label = Taggables.find(key)&.label_text || key.to_s
      typed.each do |w, t|
        errs << ::I18n.t(:error_gk_tags_not_allowed, handle: ref_of(w), type: t.name, thing: label) if t && !t.allowed_on?(key)
      end
      typed.group_by { |_, t| t&.id }.each_value do |list|
        t = list.first[1]
        next unless t&.exclusive && list.map { |w, _| ref_of(w) }.uniq.size > 1

        errs << ::I18n.t(:error_gk_tags_exclusive, type: t.name, handles: list.map { |w, _| "##{ref_of(w)}" }.uniq.join(' '))
      end
      have = typed.map { |_, t| t&.id }
      Types.active.each do |t|
        errs << ::I18n.t(:error_gk_tags_required, type: t.name, thing: label) if t.required_for?(key) && !have.include?(t.id)
      end
      errs.uniq
    end

    # Set the object's tags to exactly the wanted ones: unknown plain keys and ns:values made free tags (of the
    # namespace's type), new taggings added, the others removed (removed_at), free tags checked for establishment.
    # Returns the tags added. Never checks the rules (check does; scenarios set tags without them).
    def apply(obj, user, wanted)
      tname = type_name(obj)
      pid = obj.respond_to?(:project_id) ? obj.project_id : nil
      wanted_ids = []
      added = []
      wanted.each do |w|
        tag = w.tag
        if tag.nil?
          next unless w.status == :new

          tag = ::GkTagsTag.global.find_by(key: w.key, type_id: w.type&.id) ||
                ::GkTagsTag.create!(key: w.key, kind: 'tag', status: 'free', type_id: w.type&.id, created_by_id: user&.id)
        end
        wanted_ids << tag.id
        next if ::GkTagsTagging.active.where(taggable_type: tname, taggable_id: obj.id, tag_id: tag.self_and_merged_ids).exists?

        ::GkTagsTagging.create!(tag_id: tag.id, taggable_type: tname, taggable_id: obj.id, project_id: pid, tagger_id: user&.id,
                               source: 'manual', handle_used: w.written.to_s.sub(/\A#/, '').first(80), created_at: ::Time.current)
        added << tag
      end
      keep = ::GkTagsTag.where(id: wanted_ids).flat_map(&:self_and_merged_ids)
      ::GkTagsTagging.active.where(taggable_type: tname, taggable_id: obj.id).joins(:tag).where(gk_tags_tags: { kind: 'tag' })
                    .where.not(tag_id: keep).find_each { |t| t.remove!(user) }
      added.each { |t| GkTags.check_established(t) }
      added
    end
  end

  # What a registered class gets (Taggables.attach). The owner's form and REST set gk_tag_list; the save checks it as
  # the issue's tag field is checked and then sets the tags. Nothing happens while tags.objects is off or for someone
  # who may not change the object's tags (the list is refused).
  module Taggable
    def self.included(base)
      base.validate :gk_tags_validate_list
      base.after_save :gk_tags_apply
    end

    def gk_tags_current_tags = GkTags::Tagging.tags_of(self)
    def gk_tag_list = gk_tags_current_tags.map(&:ref).join(' ')

    # Text from REST, a list from the form's chooser
    def gk_tag_list=(value)
      @gk_tags_input = GkTags.list_text(value)
      @gk_tags_wanted = nil
    end

    private

    def gk_tags_wanted
      return nil if @gk_tags_input.nil? || !GkTags.ready? || !GkTags::Taggables.on?(GkTags::Taggables.for_object(self))

      @gk_tags_wanted ||= GkTags::Tagging.read(@gk_tags_input)
    end

    def gk_tags_validate_list
      return unless (w = gk_tags_wanted)
      return errors.add(:base, ::I18n.t(:error_gk_tags_may_not_tag)) unless GkTags::Taggables.tag?(self)

      GkTags::Tagging.check(self, w).each { |m| errors.add(:base, m) }
    end

    def gk_tags_apply
      return unless (w = gk_tags_wanted)

      before = gk_tags_current_tags.map(&:ref).sort
      GkTags::Tagging.apply(self, ::User.current, w)
      @gk_tags_input = nil
      @gk_tags_wanted = nil
      @gk_tags_preloaded = nil
      after = gk_tags_current_tags.map(&:ref).sort
      return if before == after || !defined?(::GkRecords::Events) || !::GkRecords::Targets.for_object(self)

      ::GkRecords::Events.write(self, GkTags::OBJECT_KIND, details: { 'tags' => [before.join(' '), after.join(' ')] }, user: ::User.current)
    end
  end
end
