# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_tags_tags.
# Merged migration: the tags, marks and focus lists (001; the indexes on type_id and parent_id from 003).
# No seed data. Colour in data is a category of the shared palette, never a hue: a mark keeps its
# category (1 to 12), a tag a marking (warning or alarm), which takes the roles of those alert levels.
# The first migration's down runs last at redmine:plugins:migrate NAME=gk_tags VERSION=0: it also takes away the
# plugin's row in core's settings. The plugin keeps nothing in a person's preferences.
class CreateGkTagsTags < ActiveRecord::Migration[6.1]
  def change
    reversible { |dir| dir.down { Setting.where(name: 'plugin_gk_tags').delete_all } }
    create_table "gk_tags_tags" do |t|
      t.string "key", limit: 80, null: false
      t.string "kind", limit: 10, default: "tag", null: false
      t.string "name", limit: 255
      t.text "description"
      t.string "status", limit: 12, default: "free", null: false
      t.integer "merged_into_id"
      t.integer "owner_id"
      t.boolean "shared", default: false, null: false
      t.integer "type_id"
      t.integer "parent_id"
      t.integer "scope_project_id"
      t.integer "created_by_id"
      t.datetime "promoted_at", precision: nil
      t.integer "promoted_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.integer "category"
      t.string "marking", limit: 10
      t.index ["key", "owner_id"], name: "index_gk_tags_tags_on_key_and_owner_id"
      t.index ["kind", "owner_id"], name: "index_gk_tags_tags_on_kind_and_owner_id"
      t.index ["parent_id"], name: "index_gk_tags_tags_on_parent_id"
      t.index ["type_id"], name: "index_gk_tags_tags_on_type_id"
    end
  end
end
