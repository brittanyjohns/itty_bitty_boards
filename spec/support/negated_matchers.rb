# Composable negations, so "this writes nothing" can be asserted across several
# tables in one block:
#
#   expect { preview }.to not_change(Board, :count).and not_change(Image, :count)
#
# `expect { }.not_to change(...)` can't be chained with `.and`.
RSpec::Matchers.define_negated_matcher :not_change, :change
