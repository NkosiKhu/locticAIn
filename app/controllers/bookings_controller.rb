class BookingsController < ApplicationController
  def index
    @bookings = Booking.includes(:client, :service).all
  end

  def show
  end

  def new
  end

  def create
  end

  def edit
  end

  def update
  end

  def destroy
  end
end
