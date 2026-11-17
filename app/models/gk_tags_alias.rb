# frozen_string_literal: true

# Another handle that resolves to the same tag (### identity): a former key after a rename (former_key), or one added
# by an administrator, optionally for a language. A deprecated alias still resolves but is not suggested.
class GkTagsAlias < ApplicationRecord
  self.table_name = 'gk_tags_aliases'

  belongs_to :tag, class_name: 'GkTagsTag'

  validates :handle, presence: true, length: { maximum: 80 }, uniqueness: true
  validate :not_a_key

  private

  def not_a_key
    errors.add(:handle, :taken) if GkTagsTag.global.where(key: handle).where.not(id: tag_id).exists?
  end
end
