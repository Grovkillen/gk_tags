# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_tags_taggings.
# Merged migration: the taggings, never deleted (001).
# No seed data.
class CreateGkTagsTaggings < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_tags_taggings" do |t|
      t.integer "tag_id", null: false
      t.string "taggable_type", limit: 30, null: false
      t.integer "taggable_id", null: false
      t.integer "project_id"
      t.integer "tagger_id"
      t.string "source", limit: 10, default: "manual", null: false
      t.string "handle_used", limit: 80
      t.text "note"
      t.integer "rank"
      t.datetime "expires_at", precision: nil
      t.datetime "created_at", precision: nil, null: false
      t.datetime "removed_at", precision: nil
      t.integer "removed_by_id"
      t.index ["project_id", "tag_id"], name: "index_gk_tags_taggings_on_project_id_and_tag_id"
      t.index ["tag_id", "removed_at"], name: "index_gk_tags_taggings_on_tag_id_and_removed_at"
      t.index ["taggable_type", "taggable_id"], name: "index_gk_tags_taggings_on_taggable_type_and_taggable_id"
      t.index ["tagger_id", "tag_id", "removed_at"], name: "index_gk_tags_taggings_on_tagger_id_and_tag_id_and_removed_at"
    end
  end
end
