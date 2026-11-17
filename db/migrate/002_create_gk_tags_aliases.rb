# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_tags_aliases.
# Merged migration: the aliases (001).
# No seed data.
class CreateGkTagsAliases < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_tags_aliases" do |t|
      t.integer "tag_id", null: false
      t.string "handle", limit: 80, null: false
      t.string "language", limit: 10
      t.boolean "deprecated", default: false, null: false
      t.boolean "former_key", default: false, null: false
      t.integer "created_by_id"
      t.datetime "created_at", precision: nil, null: false
      t.index ["handle"], name: "index_gk_tags_aliases_on_handle", unique: true
      t.index ["tag_id"], name: "index_gk_tags_aliases_on_tag_id"
    end
  end
end
