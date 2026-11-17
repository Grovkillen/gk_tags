# frozen_string_literal: true

# A tag on an object (### taggables, ### history): never deleted, removed_at and removed_by_id instead. For marks it
# carries the note, for focus its place (rank).
class GkTagsTagging < ApplicationRecord
  self.table_name = 'gk_tags_taggings'

  belongs_to :tag, class_name: 'GkTagsTag'
  belongs_to :tagger, class_name: 'User', optional: true

  # Issue and Journal, and the classes other plugins register (GkTags::Taggables)
  validates :taggable_type, inclusion: { in: ->(_t) { GkTags::Taggables.type_names } }

  scope :active, -> { where(removed_at: nil) }

  def taggable = taggable_type.safe_constantize&.find_by(id: taggable_id)

  # The issue the tagging belongs to: the issue itself, or the issue of a note
  def issue
    case taggable_type
    when 'Issue' then ::Issue.find_by(id: taggable_id)
    when 'Journal' then (j = ::Journal.find_by(id: taggable_id)) && j.journalized_type == 'Issue' ? j.journalized : nil
    end
  end

  def remove!(user)
    update!(removed_at: ::Time.current, removed_by_id: user&.id)
  end
end
