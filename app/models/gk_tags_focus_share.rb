# frozen_string_literal: true

# One recipient of a person's personal markings of a kind (personal: the kind's key, focus today; GkTags::Sharing):
# scope current or history, kind manager, group,
# people_group or user (none: the person shares nothing and is not on the defaults)
class GkTagsFocusShare < ApplicationRecord
  self.table_name = 'gk_tags_focus_shares'

  belongs_to :user, class_name: 'User'

  validates :scope, inclusion: { in: %w[current history] }
  validates :kind, inclusion: { in: %w[manager group people_group user none] }
end
