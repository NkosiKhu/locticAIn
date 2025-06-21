class CreateServices < ActiveRecord::Migration[8.0]
  def change
    create_table :services do |t|
      t.string :name
      t.text :description
      t.integer :duration_minutes
      t.integer :price_cents
      t.boolean :active

      t.timestamps
    end
  end
end
