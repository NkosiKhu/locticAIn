class Service < ApplicationRecord
  has_many :bookings, dependent: :destroy
end
