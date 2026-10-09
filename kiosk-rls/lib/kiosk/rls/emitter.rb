# frozen_string_literal: true

module Kiosk
  module RLS
    # Compiles {Table} and {Policy} into PostgreSQL DDL.
    module Emitter
      class << self
        def statements_for(table)
          stmts = []
          stmts << enable_rls_sql(table.name)
          stmts << force_rls_sql(table.name) # without FORCE the table owner bypasses RLS
          stmts << grant_table_sql(table.name, table.app_role)
          table.sequences.each do |seq|
            stmts << grant_sequence_sql(seq, table.app_role)
          end
          table.policies.each do |policy|
            stmts << create_policy_sql(table.name, policy)
          end
          stmts << comment_sql(table.name, table.comment_text) if table.comment_text
          stmts
        end

        def enable_rls_sql(table_name)
          %(ALTER TABLE #{quote_ident(table_name)} ENABLE ROW LEVEL SECURITY)
        end

        def force_rls_sql(table_name)
          %(ALTER TABLE #{quote_ident(table_name)} FORCE ROW LEVEL SECURITY)
        end

        def grant_table_sql(table_name, role)
          %(GRANT SELECT, INSERT, UPDATE, DELETE ON #{quote_ident(table_name)} TO #{quote_ident(role)})
        end

        def grant_sequence_sql(sequence_name, role)
          %(GRANT USAGE, SELECT ON SEQUENCE #{quote_ident(sequence_name)} TO #{quote_ident(role)})
        end

        def create_policy_sql(table_name, policy)
          parts = [
            "CREATE POLICY #{quote_ident(policy.name)}",
            "ON #{quote_ident(table_name)}",
            "FOR #{policy.action.to_s.upcase}",
          ]
          parts << "USING (#{policy.using})"           if policy.using
          parts << "WITH CHECK (#{policy.check})"      if policy.check
          parts.join(" ")
        end

        def drop_policy_sql(table_name, policy_name)
          %(DROP POLICY IF EXISTS #{quote_ident(policy_name)} ON #{quote_ident(table_name)})
        end

        def rename_policy_sql(table_name, from_name, to_name)
          %(ALTER POLICY #{quote_ident(from_name)} ON #{quote_ident(table_name)} ) +
            %(RENAME TO #{quote_ident(to_name)})
        end

        def comment_sql(table_name, text)
          %(COMMENT ON TABLE #{quote_ident(table_name)} IS #{quote_literal(text)})
        end

        private

        def quote_ident(name)
          name.to_s.split(".").map { |part|
            %("#{part.gsub('"', '""')}")
          }.join(".")
        end

        def quote_literal(text)
          %('#{text.to_s.gsub("'", "''")}')
        end
      end
    end
  end
end
