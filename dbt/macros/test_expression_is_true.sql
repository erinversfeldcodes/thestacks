{% test expression_is_true(model, column_name, expression) %}
    select {{ column_name }}
    from {{ model }}
    where not ({{ expression }})
{% endtest %}
