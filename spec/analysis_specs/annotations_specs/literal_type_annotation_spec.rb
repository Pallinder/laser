require File.expand_path(File.dirname(__FILE__) + '/spec_helper')
describe ScopeAnnotation do
  extend AnalysisHelpers
  clean_registry
  
  it 'adds the #class_estimate method to Sexp' do
    Sexp.instance_methods.should include(:class_estimate)
  end
  
  # This is the AST that Ripper generates for the parsed code. It is
  # provided here because otherwise the test is inscrutable.
  #
  # [:program,
  # [[:assign,
  #    [:var_field, [:@ident, "a", [1, 0]]], [:@int, "5", [1, 4]]]]]
  it 'discovers the class for integer literals' do
    tree = Sexp.new(Ripper.sexp('a = 5'))
    LiteralTypeAnnotation::Annotator.new.annotate!(tree)
    list = tree[1]
    estimate = list[0][2].class_estimate
    estimate.should be_exact
    estimate.exact_class.should == ClassRegistry['Fixnum']
  end
  
  # This is the AST that Ripper generates for the parsed code. It is
  # provided here because otherwise the test is inscrutable.
  #
  # [:program,
  # [[:assign,
  #   [:var_field, [:@ident, "a", [1, 0]]],
  #   [:string_literal,
  #    [:string_content,
  #     [:@tstring_content, "abc = ", [1, 5]],
  #     [:string_embexpr,
  #      [[:binary,
  #        [:var_ref, [:@ident, "run_method", [1, 13]]],
  #        :-,
  #        [:@int, "5", [1, 26]]]]]]]]]]
  it 'discovers the class for nontrivial string literals' do
    tree = Sexp.new(Ripper.sexp('a = "abc = #{run_method - 5}"'))
    LiteralTypeAnnotation::Annotator.new.annotate!(tree)
    list = tree[1]
    estimate = list[0][2].class_estimate
    estimate.should be_exact
    estimate.exact_class.should == ClassRegistry['String']
  end
  
  # [:program,
  # [[:assign,
  #    [:var_field, [:@ident, "x", [1, 0]]],
  #    [:@float, "3.14", [1, 4]]]]]
  it 'discovers the class for float literals' do
    tree = Sexp.new(Ripper.sexp('x = 3.14'))
    LiteralTypeAnnotation::Annotator.new.annotate!(tree)
    list = tree[1]
    estimate = list[0][2].class_estimate
    estimate.should be_exact
    estimate.exact_class.should == ClassRegistry['Float']
  end
  
  # [:program,
  # [[:assign,
  #   [:var_field, [:@ident, "x", [1, 0]]],
  #   [:regexp_literal,
  #    [[:@tstring_content, "abc", [1, 5]]],
  #    [:@regexp_end, "/im", [1, 8]]]]]]
  it 'discovers the class for regexp literals' do
    tree = Sexp.new(Ripper.sexp('x = /abc/im'))
    LiteralTypeAnnotation::Annotator.new.annotate!(tree)
    list = tree[1]
    estimate = list[0][2].class_estimate
    estimate.should be_exact
    estimate.exact_class.should == ClassRegistry['Regexp']
  end
  
  # [:program,
  #  [[:assign,
  #    [:var_field, [:@ident, "x", [1, 0]]],
  #    [:array, [[:@int, "1", [1, 5]], [:@int, "2", [1, 8]]]]]]]
  it 'discovers the class for array literals' do
    tree = Sexp.new(Ripper.sexp('x = [1, 2]'))
    LiteralTypeAnnotation::Annotator.new.annotate!(tree)
    list = tree[1]
    estimate = list[0][2].class_estimate
    estimate.should be_exact
    estimate.exact_class.should == ClassRegistry['Array']
  end
  
  # [:program,
  #  [[:assign,
  #    [:var_field, [:@ident, "x", [1, 0]]],
  #    [:hash,
  #     [:assoclist_from_args,
  #      [[:assoc_new,
  #        [:@label, "a:", [1, 5]],
  #        [:symbol_literal, [:symbol, [:@ident, "b", [1, 9]]]]]]]]]]]
  it 'discovers the class for hash literals' do
    tree = Sexp.new(Ripper.sexp('x = {a: :b}'))
    LiteralTypeAnnotation::Annotator.new.annotate!(tree)
    list = tree[1]
    estimate = list[0][2].class_estimate
    estimate.should be_exact
    estimate.exact_class.should == ClassRegistry['Hash']
  end
  
  # [:program,
  #  [[:assign,
  #    [:var_field, [:@ident, "x", [1, 0]]],
  #    [:symbol_literal, [:symbol, [:@ident, "abcdef", [1, 5]]]]]]]
  it 'discovers the class for symbol literals' do
    tree = Sexp.new(Ripper.sexp('x = :abcdef'))
    LiteralTypeAnnotation::Annotator.new.annotate!(tree)
    list = tree[1]
    estimate = list[0][2].class_estimate
    estimate.should be_exact
    estimate.exact_class.should == ClassRegistry['Symbol']
  end
  
  # [:program,
  #  [[:assign,
  #    [:var_field, [:@ident, "x", [1, 0]]],
  #    [:dyna_symbol,
  #     [[:@tstring_content, "abc", [1, 6]],
  #      [:string_embexpr, [[:var_ref, [:@ident, "xyz", [1, 11]]]]],
  #      [:@tstring_content, "def", [1, 15]]]]]]]
  it 'discovers the class for dynamic symbol literals' do
    tree = Sexp.new(Ripper.sexp('x = :"abc{xyz}def"'))
    LiteralTypeAnnotation::Annotator.new.annotate!(tree)
    list = tree[1]
    estimate = list[0][2].class_estimate
    estimate.should be_exact
    estimate.exact_class.should == ClassRegistry['Symbol']
  end
end