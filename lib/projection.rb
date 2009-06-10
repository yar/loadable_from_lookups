class Projection
  def initialize(lookup_like_obj, acc_method)
    @lookup_like_obj = lookup_like_obj
    @acc_method = acc_method
  end
  
  def per(*args)
    @lookup_like_obj.send(@acc_method, *args)
  end
end