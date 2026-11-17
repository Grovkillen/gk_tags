# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_tags_focus_shares.
# Merged migration: who a person shares her focus with (002).
# No seed data.
class CreateGkTagsFocusShares < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_tags_focus_shares" do |t|
      t.integer "user_id", null: false
      t.string "scope", limit: 10, null: false
      t.string "kind", limit: 15, null: false
      t.integer "target_id"
      t.datetime "created_at", precision: nil, null: false
      t.string "personal", limit: 20, default: "focus", null: false
      t.index ["kind", "target_id"], name: "index_gk_tags_focus_shares_on_kind_and_target_id"
      t.index ["user_id", "personal", "scope"], name: "index_gk_tags_focus_shares_on_user_personal_scope"
      t.index ["user_id", "scope"], name: "index_gk_tags_focus_shares_on_user_id_and_scope"
    end
  end
end
