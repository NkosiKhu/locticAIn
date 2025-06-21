# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

puts "🌱 Seeding hair salon data..."

# Clear existing data
puts "Clearing existing data..."
Booking.destroy_all
Client.destroy_all
Service.destroy_all

# Create Services
puts "Creating services..."
services_data = [
  {
    name: "Women's Haircut & Style",
    description: "Professional haircut with wash, cut, and styling. Includes consultation on best style for your face shape.",
    duration_minutes: 60,
    price_cents: 8500, # $85.00
    active: true
  },
  {
    name: "Men's Haircut",
    description: "Classic men's haircut including wash, cut, and basic styling.",
    duration_minutes: 30,
    price_cents: 4500, # $45.00
    active: true
  },
  {
    name: "Hair Color - Full",
    description: "Complete hair coloring service including consultation, color application, and styling.",
    duration_minutes: 180,
    price_cents: 15000, # $150.00
    active: true
  },
  {
    name: "Highlights",
    description: "Partial or full highlights with foil technique. Includes toning and styling.",
    duration_minutes: 150,
    price_cents: 12000, # $120.00
    active: true
  },
  {
    name: "Blowout & Style",
    description: "Professional wash, blow dry, and styling without a cut.",
    duration_minutes: 45,
    price_cents: 5500, # $55.00
    active: true
  },
  {
    name: "Deep Conditioning Treatment",
    description: "Intensive hair treatment to repair and moisturize damaged hair.",
    duration_minutes: 30,
    price_cents: 3500, # $35.00
    active: true
  },
  {
    name: "Perm",
    description: "Traditional perm service including consultation, perm application, and styling.",
    duration_minutes: 120,
    price_cents: 9500, # $95.00
    active: true
  },
  {
    name: "Hair Extensions Application",
    description: "Professional application of clip-in or semi-permanent hair extensions.",
    duration_minutes: 90,
    price_cents: 18000, # $180.00
    active: true
  },
  {
    name: "Bridal Hair & Makeup",
    description: "Complete bridal hair styling and makeup application for your special day.",
    duration_minutes: 180,
    price_cents: 25000, # $250.00
    active: true
  },
  {
    name: "Hair Wash & Basic Dry",
    description: "Simple hair wash and basic blow dry service.",
    duration_minutes: 20,
    price_cents: 2500, # $25.00
    active: false # This one is inactive for variety
  }
]

services = services_data.map do |service_attrs|
  Service.create!(service_attrs)
end

puts "Created #{services.count} services"

# Create Clients
puts "Creating clients..."
clients_data = [
  {
    name: "Sarah Johnson",
    email: "sarah.johnson@example.com",
    phone: "(555) 123-4567",
    notes: "Prefers appointments after 2 PM. Allergic to certain hair dyes - check before coloring."
  },
  {
    name: "Michael Chen",
    email: "m.chen@example.com",
    phone: "(555) 234-5678",
    notes: "Regular client. Usually gets a trim every 6 weeks."
  },
  {
    name: "Emma Rodriguez",
    email: "emma.r@example.com",
    phone: "(555) 345-6789",
    notes: "New client. Interested in highlights. Has very fine hair."
  },
  {
    name: "David Thompson",
    email: "dthompson@example.com",
    phone: "(555) 456-7890",
    notes: "Business executive. Prefers early morning appointments."
  },
  {
    name: "Lisa Park",
    email: "lisa.park@example.com",
    phone: "(555) 567-8901",
    notes: "Getting married next month. Booked for bridal trial and wedding day."
  },
  {
    name: "James Wilson",
    email: "jwilson@example.com",
    phone: "(555) 678-9012",
    notes: "Prefers male stylists. Usually gets a fade cut."
  },
  {
    name: "Amanda Foster",
    email: "amanda.foster@example.com",
    phone: "(555) 789-0123",
    notes: "Comes in every 3 months for color touch-ups. Uses premium products only."
  },
  {
    name: "Robert Martinez",
    email: "r.martinez@example.com",
    phone: "(555) 890-1234",
    notes: "Senior citizen discount applied. Very loyal customer for over 10 years."
  },
  {
    name: "Jennifer Lee",
    email: "jlee@example.com",
    phone: "(555) 901-2345",
    notes: "Travels frequently for work. Often reschedules appointments."
  },
  {
    name: "Christopher Davis",
    email: "chris.davis@example.com",
    phone: "(555) 012-3456",
    notes: "First-time client. Referred by Jennifer Lee."
  }
]

clients = clients_data.map do |client_attrs|
  Client.create!(client_attrs)
end

puts "Created #{clients.count} clients"

# Create Bookings
puts "Creating bookings..."
booking_statuses = ["scheduled", "completed", "cancelled", "no_show", "confirmed"]

# Helper method to create realistic booking times
def random_time_in_range(days_ago, days_ahead = 0)
  start_date = days_ago.days.ago.beginning_of_day + 9.hours # 9 AM
  end_date = days_ahead.days.from_now.end_of_day - 5.hours # 7 PM
  
  # Exclude Sundays (assuming salon is closed)
  loop do
    time = rand(start_date..end_date)
    return time unless time.sunday?
  end
end

bookings_data = []

# Create some past completed bookings
15.times do
  client = clients.sample
  service = services.select(&:active).sample
  start_time = random_time_in_range(30, 0) # Last 30 days
  
  bookings_data << {
    client: client,
    service: service,
    start_time: start_time,
    end_time: start_time + service.duration_minutes.minutes,
    status: "completed",
    notes: ["Great session!", "Client loved the result", "Regular maintenance appointment", ""].sample
  }
end

# Create some upcoming scheduled bookings
10.times do
  client = clients.sample
  service = services.select(&:active).sample
  start_time = random_time_in_range(0, 14) # Next 2 weeks
  
  bookings_data << {
    client: client,
    service: service,
    start_time: start_time,
    end_time: start_time + service.duration_minutes.minutes,
    status: ["scheduled", "confirmed"].sample,
    notes: ["First-time service", "Regular appointment", "Special occasion", ""].sample
  }
end

# Create a few cancelled and no-show bookings
5.times do
  client = clients.sample
  service = services.select(&:active).sample
  start_time = random_time_in_range(7, 0) # Last week
  
  bookings_data << {
    client: client,
    service: service,
    start_time: start_time,
    end_time: start_time + service.duration_minutes.minutes,
    status: ["cancelled", "no_show"].sample,
    notes: ["Client called to cancel", "Family emergency", "Didn't show up", "Rescheduled for next week"].sample
  }
end

# Create some specific scenario bookings
# Bridal client with multiple appointments
bridal_client = Client.find_by(name: "Lisa Park")
bridal_service = Service.find_by(name: "Bridal Hair & Makeup")
trial_date = 2.weeks.from_now.beginning_of_day + 10.hours
wedding_date = 1.month.from_now.beginning_of_day + 8.hours

bookings_data << {
  client: bridal_client,
  service: Service.find_by(name: "Women's Haircut & Style"),
  start_time: trial_date,
  end_time: trial_date + 60.minutes,
  status: "scheduled",
  notes: "Bridal trial run - practice for wedding day"
}

bookings_data << {
  client: bridal_client,
  service: bridal_service,
  start_time: wedding_date,
  end_time: wedding_date + 180.minutes,
  status: "scheduled",
  notes: "WEDDING DAY! Very important - double check all details"
}

# Regular client with recurring appointments
regular_client = Client.find_by(name: "Michael Chen")
mens_cut = Service.find_by(name: "Men's Haircut")

# Past appointments
3.times do |i|
  appointment_date = (6 * (i + 1)).weeks.ago.beginning_of_day + 11.hours
  bookings_data << {
    client: regular_client,
    service: mens_cut,
    start_time: appointment_date,
    end_time: appointment_date + mens_cut.duration_minutes.minutes,
    status: "completed",
    notes: "Regular 6-week trim"
  }
end

# Future appointment
next_appointment = 2.weeks.from_now.beginning_of_day + 11.hours
bookings_data << {
  client: regular_client,
  service: mens_cut,
  start_time: next_appointment,
  end_time: next_appointment + mens_cut.duration_minutes.minutes,
  status: "confirmed",
  notes: "Regular 6-week trim"
}

# Create all bookings
bookings = bookings_data.map do |booking_attrs|
  Booking.create!(booking_attrs)
end

puts "Created #{bookings.count} bookings"

# Print summary
puts "\n✅ Seed data created successfully!"
puts "📊 Summary:"
puts "   Services: #{Service.count} (#{Service.where(active: true).count} active)"
puts "   Clients: #{Client.count}"
puts "   Bookings: #{Booking.count}"
puts "     - Completed: #{Booking.where(status: 'completed').count}"
puts "     - Scheduled: #{Booking.where(status: 'scheduled').count}"
puts "     - Confirmed: #{Booking.where(status: 'confirmed').count}"
puts "     - Cancelled: #{Booking.where(status: 'cancelled').count}"
puts "     - No-shows: #{Booking.where(status: 'no_show').count}"
puts "\n🎉 Your hair salon booking system is ready to use!"
puts "💡 Try running: rails console"
# puts "   Then: Booking.includes(:client, :service).limit(5).each { |b| puts \"#{b.client.name} - #{b.service.name} - #{b.start_time}\" }"
