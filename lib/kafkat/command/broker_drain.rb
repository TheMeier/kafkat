# frozen_string_literal: true

module Kafkat
  module Command
    class BrokerDrain < Base
      register_as 'broker_drain', deprecated: 'drain'
      banner 'kafkat broker drain BROKER'
      description 'Drain topics from a broker'

      option :topic,
        short: '-T',
        long: '--topic TOPIC',
        description: 'The topic to reassign (empty for all)'

      option :brokers,
        short: '-B',
        long: '--brokers BROKERS',
        description: 'The destination brokers for the topic'

      # For each partition (of specified topic) on the source broker, the command is to
      # assign the partition to one of the destination brokers that does not already have
      # this partition, along with existing brokers to achieve minimal movement of data.
      # To help distribute data evenly, if there are more than one destination brokers
      # meet the requirement, the command will always choose the brokers with the lowest
      # number of partitions of the involving topic.
      #
      # In order to find out the broker with lowest number of partitions, the command maintain
      # a hash table with broker id as key and number of partitions as value. The hash table
      # will be updated along with assignment.
      def run
        source_broker = arguments.last
        if source_broker.nil?
          puts 'You must specify a broker ID.'
          exit 1
        end

        topic_name = config[:topic]
        topics = topic_name && zookeeper.topics([topic_name])
        topics ||= zookeeper.topics

        destination_brokers = config[:brokers]&.split(',')&.map(&:to_i)
        destination_brokers ||= zookeeper.brokers.values.map(&:id)
        destination_brokers.delete(source_broker)

        active_brokers = zookeeper.brokers.values.map(&:id)

        unless (inactive_brokers = destination_brokers - active_brokers).empty?
          print "ERROR: Broker #{inactive_brokers} are not currently active.\n"
          exit 1
        end

        assignments =
          generate_assignments(source_broker, topics, destination_brokers)

        print "Num of topics got from zookeeper: #{topics.length}\n"
        print "Num of partitions in the assignment: #{assignments.size}\n"
        prompt_and_execute_assignments(assignments)
      end

      def generate_assignments(source_broker, topics, destination_brokers)
        assignments = []
        topics.each do |_, t|
          partitions_by_broker = build_partitions_by_broker(t, destination_brokers)

          t.partitions.each do |p|
            next unless p.replicas.include?(source_broker)

            replicas_size = p.replicas.length
            replicas = p.replicas - [source_broker]
            source_broker_is_leader = p.replicas.first == source_broker
            potential_broker_ids = destination_brokers - replicas
            if potential_broker_ids.empty?
              print "ERROR: Not enough destination brokers to reassign topic \"#{t.name}\".\n"
              exit 1
            end

            num_partitions_on_potential_broker =
              partitions_by_broker.select { |id, _| potential_broker_ids.include?(id) }
            assigned_broker_id = num_partitions_on_potential_broker.min_by { |_, num| num }[0]
            if source_broker_is_leader
              replicas.unshift(assigned_broker_id)
            else
              replicas << assigned_broker_id
            end
            partitions_by_broker[assigned_broker_id] += 1

            if replicas.length != replicas_size
              STDERR.print "ERROR: Number of replicas changes after reassignment topic: #{t.name}, partition: #{p.id} \n"
              exit 1
            end

            assignments << Assignment.new(t.name, p.id, replicas)
          end
        end

        assignments
      end

      # Build a hash map from broker id to number of partitions on it to facilitate
      # finding the broker with lowest number of partitions to help balance brokers.
      def build_partitions_by_broker(topic, destination_brokers)
        partitions_by_broker = Hash.new(0)
        destination_brokers.each { |id| partitions_by_broker[id] = 0 }
        topic.partitions.each do |p|
          p.replicas.each do |r|
            partitions_by_broker[r] += 1
          end
        end
        partitions_by_broker
      end
    end
  end
end
