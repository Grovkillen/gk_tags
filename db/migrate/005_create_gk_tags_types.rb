# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_tags_types.
# Merged migration: the tag types as data (003).
class CreateGkTagsTypes < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_tags_types" do |t|
      t.string "key", limit: 40, null: false
      t.string "icon", limit: 80
      t.boolean "exclusive", default: false, null: false
      t.text "allowed_on"
      t.text "required_for"
      t.string "namespace", limit: 40
      t.boolean "inherit_parents", default: true, null: false
      t.boolean "repeat_keys", default: false, null: false
      t.integer "position", default: 0, null: false
      t.boolean "active", default: true, null: false
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.string "name", limit: 255
      t.text "description"
      t.integer "category"
      t.index ["key"], name: "index_gk_tags_types_on_key", unique: true
      t.index ["namespace"], name: "index_gk_tags_types_on_namespace"
    end
  end
end
