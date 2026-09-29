# frozen_string_literal: true

# `kiosk.schema_major()` on a database whose kiosk genesis predates it. The
# engine reads it at boot and refuses a gem two or more majors ahead of this
# schema; a fresh `kiosk:install` gets it from migration 001 and needs no
# separate file.
class AddKioskSchemaMajor < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.schema_major_sql(schema: "kiosk")
  end

  def down
    execute %(DROP FUNCTION IF EXISTS "kiosk".schema_major())
  end
end
