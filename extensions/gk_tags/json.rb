# frozen_string_literal: true

module GkTags
  # REST JSON (plugins/tags ### api) for the tags, a person's marks and the focus board. People go through records'
  # Visibility: an account the viewer may not see is given as id null and hidden true.
  module Json
    module_function

    def records? = defined?(::GkRecords::Visibility)

    def user_visible?(user, viewer = ::User.current)
      return true unless records? && ::GkRecords::Visibility.respond_to?(:visible_user?)

      ::GkRecords::Visibility.visible_user?(user, viewer)
    end

    def user(key, user, viewer = ::User.current)
      return { key => user&.id } unless user && records? && ::GkRecords::Visibility.respond_to?(:api_user)

      ::GkRecords::Visibility.api_user(key, user.id, user, viewer)
    end

    # With the type (its key, null for none: the type free), how the tag is written (ref), the parent and the path
    # (keys and names from the root)
    def tag(t, count = nil)
      { id: t.id, key: t.key, ref: t.ref, name: t.name, description: t.description, marking: t.marking, status: t.status,
        type: t.type&.key, parent: t.parent ? { id: t.parent.id, key: t.parent.key } : nil, path: t.path_key, path_name: t.path_label,
        merged_into: t.merged_into&.key, aliases: t.aliases.map { |a| { handle: a.handle, language: a.language, deprecated: a.deprecated } },
        taggings: count }
    end

    # A type with its names and descriptions per language and its rules
    def type(t, count = nil)
      { id: t.id, key: t.key, name: t.name, names: t.names_hash, description: t.description, descriptions: t.descriptions_hash,
        category: t.category, icon: t.icon, exclusive: t.exclusive, allowed_on: t.allowed_on_list, required_for: t.required_for_list,
        namespace: t.namespace, inherit_parents: t.inherit_parents, repeat_keys: t.repeat_keys, position: t.position,
        active: t.active, tags: count }
    end

    # One's own mark with the slip; someone else's shared mark without it
    def mark(tagging, viewer)
      own = tagging.tag.owner_id == viewer.id
      { id: tagging.id, mark: tagging.tag.key, mark_name: tagging.tag.name, object_type: tagging.taggable_type, object_id: tagging.taggable_id,
        issue_id: tagging.issue&.id, marked_at: tagging.created_at, note: (own ? tagging.note : nil) }
    end

    # No rank, the items in priority and due date order; only one's own focus and focus shared with the viewer reach
    # here (FocusSharing)
    def focus_row(row)
      user(:user_id, row[:user]).merge(
        items: row[:items].map { |i| { issue_id: i[:issue]&.id, hidden: i[:issue].nil?, since: i[:tagging].created_at } }
      )
    end
  end
end
