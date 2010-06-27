# encoding: utf-8
# Copyright (c) 2009 Symétrie (http://symetrie.com)
# Written by Thomas Chambon

module ActsAsXapian
  module Fuzzy_Date
    class FuzzyDateMatchDecider < Xapian::MatchDecider
      def set_criteria(begin_date, end_date)
        @begin_date = begin_date.to_i
        if(end_date)
          @end_date = end_date.to_i
        else
          @end_date = @begin_date
        end
      end

      def __call__(doc)
        return true if !doc.values || !doc.values[0]
        date_data = doc.values[0].value.split("/")

        #first tab integer shows the date type
        case date_data[0].to_i
          #exact date
        when 1
          return @begin_date <= date_data[1].to_i && @end_date >= date_data[1].to_i
          #series of exact date
        when 2
          for date in date_data[1..-1]
            return true if @begin_date <= date.to_i && @end_date >= date.to_i
          end
          #interval of two dates
        when 3
          return (date_data[1].to_i <= @end_date && @begin_date <= date_data[2].to_i)
        end
        false
      end

    end
  end
end
