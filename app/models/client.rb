class Client < ApplicationRecord
  has_many :bookings, dependent: :destroy
end
