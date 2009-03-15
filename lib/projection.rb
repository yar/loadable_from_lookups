class Projection
  def initialize(forecast, acc_method)
    @forecast = forecast
    @acc_method = acc_method
  end
  
  def per(*args)
    @forecast.send(@acc_method, *args)
  end
end