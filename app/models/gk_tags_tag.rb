# frozen_string_literal: true

# A tag (plugins/tags ### tags, ### identity). kind tag is shared by everyone; kind mark and focus belong to a person
# (owner_id, the namespace @me). A global tag's key is unique among the keys and aliases of global tags; a personal
# one only among its owner's own.
class GkTagsTag < ApplicationRecord
  self.table_name = 'gk_tags_tags'

  # A hierarchy deeper than this is treated as broken (a cycle written past the validation): the walk stops
  MAX_DEPTH = 30
  # The role of a tag without a type or a category in gui_stuff's primitives: the muted one
  NO_TYPE_ROLE = 'muted'

  belongs_to :owner, class_name: 'User', optional: true
  belongs_to :merged_into, class_name: 'GkTagsTag', optional: true
  belongs_to :type, class_name: 'GkTagsType', optional: true
  belongs_to :parent, class_name: 'GkTagsTag', optional: true
  has_many :children, class_name: 'GkTagsTag', foreign_key: :parent_id
  has_many :aliases, -> { order(:handle) }, class_name: 'GkTagsAlias', foreign_key: :tag_id, dependent: :destroy
  has_many :taggings, class_name: 'GkTagsTagging', foreign_key: :tag_id

  validates :key, presence: true, length: { maximum: 80 }
  validates :kind, inclusion: { in: GkTags::KINDS }
  validates :status, inclusion: { in: GkTags::STATUSES }
  validates :name, length: { maximum: 255 }
  validates :category, inclusion: { in: GkTags::CATEGORIES }, allow_nil: true
  validates :marking, inclusion: { in: GkTags::MARKINGS }, allow_blank: true
  validate :key_free
  validate :parent_ok

  scope :global, -> { where(kind: 'tag', owner_id: nil) }
  scope :usable, -> { where.not(status: %w[merged]) }
  scope :sorted, -> { order(:key) }

  def personal? = owner_id.present?
  def label = name.presence || key
  def active_taggings = taggings.where(removed_at: nil)

  # The tag itself and the tags merged into it (a merged tag works as an alias, ### tags)
  def self_and_merged_ids = [id] + GkTagsTag.where(merged_into_id: id).pluck(:id)

  # The type whose rules the tag follows: its own, or free for a tag without one
  def rule_type = type || GkTags::Types.free

  # Parent, grandparent and so on, nearest first
  def ancestors
    out = []
    seen = { id => true }
    t = parent
    while t && !seen[t.id] && out.size < MAX_DEPTH
      out << t
      seen[t.id] = true
      t = t.parent
    end
    out
  end

  # Children, grandchildren and so on, whatever their type: the ids a parent may never be (no cycle)
  def descendant_ids
    out = []
    frontier = [id]
    MAX_DEPTH.times do
      frontier = GkTagsTag.where(parent_id: frontier).where.not(id: out + [id]).pluck(:id)
      break if frontier.empty?

      out.concat(frontier)
    end
    out
  end

  def path_tags = ancestors.reverse + [self]
  # Teknik/CAN/CANopen: the names (or keys) from the root down
  def path_label = path_tags.map(&:label).join('/')
  # teknik/can/canopen: what a person writes when the leaf alone is ambiguous
  def path_key = path_tags.map(&:key).join('/')

  # How the tag is written in a tag field: ns:key for a namespaced type, the path for a type with repeat_keys (and a
  # parent), else the key
  def ref
    t = type
    body = t&.repeat_keys && parent_id ? path_key : key
    t&.namespaced? ? "#{t.namespace}:#{body}" : body
  end

  # The pill's classes: a marking (warning, alarm) when the tag has one, else its own category (a mark) or its type's
  # (the type shows in the edge, the marking in the pill)
  def pill_classes
    return "gk-tags-pill-marking gk-tags-marking-#{marking}" if marking.present?

    cat = category || type&.category
    cat ? "gk-tags-pill-cat gk-tags-cat-#{cat}" : 'gk-tags-pill-none'
  end

  # The role of the tag's pill in gui_stuff's primitives (gk_gui_stuff_pill): its marking (warning, alarm), else its
  # own category (a mark) or its type's, else the muted role of a tag without type
  def pill_role = marking.presence || category || type&.category || NO_TYPE_ROLE

  private

  # Unique among global keys and aliases (or among the owner's own personal tags of the kind); within its type for a
  # namespaced type; tags of a type with repeat_keys under other parents do not clash
  def key_free
    k = key.to_s
    if personal?
      clash = GkTagsTag.where(owner_id: owner_id, kind: kind, key: k).where.not(id: id).exists?
    else
      t = type
      others = GkTagsTag.global.where(key: k).where.not(id: id).to_a
      if t&.namespaced?
        others = others.select { |o| o.type_id == t.id }
      else
        ns_ids = GkTags::Types.namespaced_ids
        others = others.reject { |o| ns_ids.include?(o.type_id) }
      end
      others = others.reject { |o| o.type_id == t.id && o.parent_id != parent_id } if t&.repeat_keys
      clash = others.any? || (!t&.namespaced? && GkTagsAlias.joins(:tag).where(handle: k).where.not(tag_id: id).exists?)
    end
    errors.add(:key, :taken) if clash
  end

  # A parent is a global tag, not merged, and never the tag itself or one of its descendants (no cycle)
  def parent_ok
    return if parent_id.nil?
    return errors.add(:parent_id, :invalid) if personal? || kind != 'tag'

    p = GkTagsTag.global.find_by(id: parent_id)
    return errors.add(:parent_id, :invalid) unless p && p.status != 'merged'
    return errors.add(:base, ::I18n.t(:error_gk_tags_cycle)) if p.id == id || (id && p.ancestors.any? { |a| a.id == id })
  end
end
