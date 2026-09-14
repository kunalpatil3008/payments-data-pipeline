{#
  Overrides dbt's default schema naming.

  Default behaviour joins the target schema and the custom schema:
      STAGING + staging  ->  STAGING_STAGING

  That default exists so several developers can share one warehouse without
  overwriting each other. On a solo project it just makes ugly names.

  This version uses the custom schema exactly as written in dbt_project.yml,
  so models land in STAGING and MARTS.
#}

{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}

    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim | upper }}
    {%- endif -%}

{%- endmacro %}
