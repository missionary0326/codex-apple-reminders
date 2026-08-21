#import <AppKit/AppKit.h>
#import <CoreLocation/CoreLocation.h>
#import <EventKit/EventKit.h>
#import <Foundation/Foundation.h>

static NSString *const ErrorDomain = @"CodexAppleReminders";

static NSError *MakeError(NSString *message) {
    return [NSError errorWithDomain:ErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *WrapError(NSString *prefix, NSError *error) {
    if (error == nil) return MakeError(prefix);
    return MakeError([NSString stringWithFormat:@"%@: %@", prefix, error.localizedDescription]);
}

static BOOL HasKey(NSDictionary *input, NSString *key) {
    return input[key] != nil && input[key] != NSNull.null;
}

static NSString *OptionalString(NSDictionary *input, NSString *key) {
    id value = input[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSString *RequiredString(NSDictionary *input, NSString *key, NSError **error) {
    NSString *value = OptionalString(input, key);
    if (value == nil || [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) {
        if (error) *error = MakeError([NSString stringWithFormat:@"Missing required field: %@", key]);
        return nil;
    }
    return value;
}

static NSArray *OptionalArray(NSDictionary *input, NSString *key, NSError **error) {
    id value = input[key];
    if (value == nil || value == NSNull.null) return nil;
    if (![value isKindOfClass:NSArray.class]) {
        if (error) *error = MakeError([NSString stringWithFormat:@"%@ must be an array.", key]);
        return nil;
    }
    return value;
}

static BOOL RequestReminderAccess(EKEventStore *store, NSError **error) {
    if (@available(macOS 14.0, *)) {
        EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder];
        if (status == EKAuthorizationStatusFullAccess) return YES;
        if (status == EKAuthorizationStatusDenied) {
            if (error) *error = MakeError(@"Reminders access is denied. Enable Codex Apple Reminders in System Settings > Privacy & Security > Reminders.");
            return NO;
        }
        if (status == EKAuthorizationStatusRestricted) {
            if (error) *error = MakeError(@"Reminders access is restricted by system policy or parental controls.");
            return NO;
        }
        if (status == EKAuthorizationStatusWriteOnly) {
            if (error) *error = MakeError(@"The helper has write-only Reminders access, but full access is required. Update permission in System Settings > Privacy & Security > Reminders.");
            return NO;
        }

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block BOOL granted = NO;
        __block NSError *accessError = nil;
        [store requestFullAccessToRemindersWithCompletion:^(BOOL allowed, NSError *requestError) {
            granted = allowed;
            accessError = requestError;
            dispatch_semaphore_signal(semaphore);
        }];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        if (accessError != nil) {
            if (error) *error = WrapError(@"Unable to request full Reminders access", accessError);
            return NO;
        }
        if (!granted) {
            if (error) *error = MakeError(@"Full Reminders access was not granted. Enable it in System Settings > Privacy & Security > Reminders.");
            return NO;
        }
        return YES;
    }
    if (error) *error = MakeError(@"Apple Reminders plugin 0.2.0 requires macOS 14 or newer.");
    return NO;
}

static NSString *ISODateString(NSDate *date) {
    NSISO8601DateFormatter *formatter = NSISO8601DateFormatter.new;
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:date];
}

static NSDate *DateFromISO(NSString *raw, NSTimeZone *dateOnlyTimeZone, NSError **error) {
    if (raw.length == 0) {
        if (error) *error = MakeError(@"Date value must not be empty.");
        return nil;
    }
    NSRegularExpression *dateOnly = [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2}$" options:0 error:nil];
    if ([dateOnly firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)] != nil) {
        NSArray<NSString *> *parts = [raw componentsSeparatedByString:@"-"];
        NSDateComponents *components = NSDateComponents.new;
        NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        calendar.timeZone = dateOnlyTimeZone ?: NSTimeZone.localTimeZone;
        components.calendar = calendar;
        components.timeZone = calendar.timeZone;
        components.year = parts[0].integerValue;
        components.month = parts[1].integerValue;
        components.day = parts[2].integerValue;
        NSDate *date = [calendar dateFromComponents:components];
        NSDateComponents *roundTrip = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:date];
        if (date == nil || roundTrip.year != components.year || roundTrip.month != components.month || roundTrip.day != components.day) {
            if (error) *error = MakeError([NSString stringWithFormat:@"Invalid calendar date: %@", raw]);
            return nil;
        }
        return date;
    }

    NSISO8601DateFormatter *fractional = NSISO8601DateFormatter.new;
    fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSISO8601DateFormatter *normal = NSISO8601DateFormatter.new;
    normal.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSDate *date = [fractional dateFromString:raw] ?: [normal dateFromString:raw];
    if (date == nil && error) *error = MakeError([NSString stringWithFormat:@"Invalid date '%@'. Use YYYY-MM-DD or RFC 3339.", raw]);
    return date;
}

static NSTimeZone *TimeZoneFromInput(NSDictionary *input, NSError **error) {
    NSString *name = OptionalString(input, @"timezone");
    if (name.length == 0) return NSTimeZone.localTimeZone;
    NSTimeZone *zone = [NSTimeZone timeZoneWithName:name];
    if (zone == nil && error) *error = MakeError([NSString stringWithFormat:@"Unknown timezone: %@", name]);
    return zone;
}

static NSDateComponents *DateComponentsFromString(NSString *raw, NSTimeZone *timezone, NSError **error) {
    BOOL allDay = [raw rangeOfString:@"T"].location == NSNotFound;
    NSDate *date = DateFromISO(raw, timezone, error);
    if (date == nil) return nil;
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = timezone ?: NSTimeZone.localTimeZone;
    NSCalendarUnit units = NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay;
    if (!allDay) units |= NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;
    NSDateComponents *components = [calendar components:units fromDate:date];
    components.calendar = calendar;
    components.timeZone = calendar.timeZone;
    return components;
}

static NSDate *DateFromComponents(NSDateComponents *components) {
    if (components == nil) return nil;
    NSCalendar *calendar = components.calendar ?: [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = components.timeZone ?: NSTimeZone.localTimeZone;
    return [calendar dateFromComponents:components];
}

static NSString *DateOnlyString(NSDateComponents *components) {
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)components.year, (long)components.month, (long)components.day];
}

static NSDictionary *ComponentsJSON(NSDateComponents *components) {
    if (components == nil) return nil;
    BOOL allDay = components.hour == NSDateComponentUndefined;
    NSMutableDictionary *result = [@{
        @"date": DateOnlyString(components),
        @"year": @(components.year),
        @"month": @(components.month),
        @"day": @(components.day),
        @"allDay": @(allDay),
    } mutableCopy];
    if (!allDay) {
        result[@"hour"] = @(components.hour);
        if (components.minute != NSDateComponentUndefined) result[@"minute"] = @(components.minute);
        if (components.second != NSDateComponentUndefined) result[@"second"] = @(components.second);
        NSDate *date = DateFromComponents(components);
        if (date != nil) result[@"dateTime"] = ISODateString(date);
    }
    if (components.timeZone.name.length > 0) result[@"timezone"] = components.timeZone.name;
    return result;
}

static NSString *SourceTypeString(EKSourceType type) {
    switch (type) {
        case EKSourceTypeLocal: return @"local";
        case EKSourceTypeExchange: return @"exchange";
        case EKSourceTypeCalDAV: return @"caldav";
        case EKSourceTypeMobileMe: return @"mobileme";
        case EKSourceTypeSubscribed: return @"subscribed";
        case EKSourceTypeBirthdays: return @"birthdays";
    }
    return @"unknown";
}

static NSString *CalendarColorHex(EKCalendar *calendar) {
    NSColor *color = [calendar.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (color == nil) return nil;
    NSInteger red = lround(color.redComponent * 255.0);
    NSInteger green = lround(color.greenComponent * 255.0);
    NSInteger blue = lround(color.blueComponent * 255.0);
    return [NSString stringWithFormat:@"#%02lX%02lX%02lX", (long)red, (long)green, (long)blue];
}

static BOOL ApplyCalendarColor(EKCalendar *calendar, NSString *raw, NSError **error) {
    if (raw == nil) return YES;
    NSRegularExpression *hex = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9A-Fa-f]{6}$" options:0 error:nil];
    if ([hex firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)] == nil) {
        if (error) *error = MakeError(@"color must use #RRGGBB format.");
        return NO;
    }
    unsigned value = 0;
    [[NSScanner scannerWithString:[raw substringFromIndex:1]] scanHexInt:&value];
    calendar.color = [NSColor colorWithSRGBRed:((value >> 16) & 0xff) / 255.0
                                        green:((value >> 8) & 0xff) / 255.0
                                         blue:(value & 0xff) / 255.0
                                        alpha:1.0];
    return YES;
}

static NSDictionary *SourceJSON(EKSource *source) {
    NSArray<EKCalendar *> *calendars = [[source calendarsForEntityType:EKEntityTypeReminder].allObjects sortedArrayUsingComparator:^NSComparisonResult(EKCalendar *left, EKCalendar *right) {
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];
    NSMutableArray *listIds = NSMutableArray.array;
    for (EKCalendar *calendar in calendars) [listIds addObject:calendar.calendarIdentifier ?: @""];
    return @{
        @"id": source.sourceIdentifier ?: @"",
        @"name": source.title ?: @"",
        @"type": SourceTypeString(source.sourceType),
        @"isDelegate": @(source.isDelegate),
        @"reminderListIds": listIds,
    };
}

static NSDictionary *CalendarJSON(EKCalendar *calendar, EKEventStore *store) {
    NSMutableDictionary *result = [@{
        @"id": calendar.calendarIdentifier ?: @"",
        @"name": calendar.title ?: @"",
        @"sourceId": calendar.source.sourceIdentifier ?: @"",
        @"source": calendar.source.title ?: @"",
        @"sourceType": SourceTypeString(calendar.source.sourceType),
        @"writable": @(calendar.allowsContentModifications),
        @"immutable": @(calendar.isImmutable),
        @"subscribed": @(calendar.isSubscribed),
        @"allowsReminders": @((calendar.allowedEntityTypes & EKEntityMaskReminder) != 0),
        @"allowsEvents": @((calendar.allowedEntityTypes & EKEntityMaskEvent) != 0),
        @"isDefault": @([store.defaultCalendarForNewReminders.calendarIdentifier isEqualToString:calendar.calendarIdentifier]),
    } mutableCopy];
    NSString *color = CalendarColorHex(calendar);
    if (color != nil) result[@"color"] = color;
    return result;
}

static NSArray<EKCalendar *> *SortedCalendars(EKEventStore *store) {
    return [[store calendarsForEntityType:EKEntityTypeReminder] sortedArrayUsingComparator:^NSComparisonResult(EKCalendar *left, EKCalendar *right) {
        NSComparisonResult source = [left.source.title localizedCaseInsensitiveCompare:right.source.title];
        return source == NSOrderedSame ? [left.title localizedCaseInsensitiveCompare:right.title] : source;
    }];
}

static EKCalendar *CalendarFromInput(NSDictionary *input, EKEventStore *store, BOOL allowDefault, NSError **error) {
    NSString *identifier = OptionalString(input, @"list_id");
    if (identifier.length > 0) {
        EKCalendar *calendar = [store calendarWithIdentifier:identifier];
        if (calendar != nil && (calendar.allowedEntityTypes & EKEntityMaskReminder) != 0) return calendar;
        if (error) *error = MakeError([NSString stringWithFormat:@"Reminder list not found for id: %@", identifier]);
        return nil;
    }

    NSString *name = OptionalString(input, @"list");
    if (name.length > 0) {
        NSMutableArray<EKCalendar *> *matches = NSMutableArray.array;
        for (EKCalendar *calendar in [store calendarsForEntityType:EKEntityTypeReminder]) {
            if ([calendar.title caseInsensitiveCompare:name] == NSOrderedSame) [matches addObject:calendar];
        }
        if (matches.count == 1) return matches.firstObject;
        if (matches.count > 1) {
            if (error) *error = MakeError([NSString stringWithFormat:@"More than one list is named '%@'. Use list_id.", name]);
            return nil;
        }
        if (error) {
            NSArray *names = [SortedCalendars(store) valueForKey:@"title"];
            *error = MakeError([NSString stringWithFormat:@"Reminder list '%@' was not found. Available lists: %@", name, [names componentsJoinedByString:@", "]]);
        }
        return nil;
    }

    if (allowDefault) {
        EKCalendar *calendar = store.defaultCalendarForNewReminders;
        if (calendar != nil) return calendar;
        if (error) *error = MakeError(@"No default Reminders list is available.");
        return nil;
    }
    if (error) *error = MakeError(@"Provide list_id or list.");
    return nil;
}

static NSArray<EKCalendar *> *SelectedCalendars(NSDictionary *input, EKEventStore *store, NSError **error) {
    if (!HasKey(input, @"list_id") && !HasKey(input, @"list")) return nil;
    EKCalendar *calendar = CalendarFromInput(input, store, NO, error);
    return calendar == nil ? nil : @[calendar];
}

static EKSource *SourceFromInput(NSDictionary *input, EKEventStore *store, NSError **error) {
    NSString *sourceId = OptionalString(input, @"source_id");
    if (sourceId.length > 0) {
        EKSource *source = [store sourceWithIdentifier:sourceId];
        if (source != nil) return source;
        if (error) *error = MakeError([NSString stringWithFormat:@"Reminder source not found for id: %@", sourceId]);
        return nil;
    }
    EKSource *source = store.defaultCalendarForNewReminders.source;
    if (source == nil && error) *error = MakeError(@"No default Reminders account/source is available.");
    return source;
}

static NSString *WeekdayString(EKWeekday day) {
    switch (day) {
        case EKWeekdaySunday: return @"sunday";
        case EKWeekdayMonday: return @"monday";
        case EKWeekdayTuesday: return @"tuesday";
        case EKWeekdayWednesday: return @"wednesday";
        case EKWeekdayThursday: return @"thursday";
        case EKWeekdayFriday: return @"friday";
        case EKWeekdaySaturday: return @"saturday";
    }
    return @"unknown";
}

static EKWeekday WeekdayFromString(NSString *raw) {
    NSDictionary *values = @{
        @"sunday": @(EKWeekdaySunday), @"monday": @(EKWeekdayMonday), @"tuesday": @(EKWeekdayTuesday),
        @"wednesday": @(EKWeekdayWednesday), @"thursday": @(EKWeekdayThursday),
        @"friday": @(EKWeekdayFriday), @"saturday": @(EKWeekdaySaturday),
    };
    return [values[raw.lowercaseString] integerValue];
}

static NSString *FrequencyString(EKRecurrenceFrequency frequency) {
    switch (frequency) {
        case EKRecurrenceFrequencyDaily: return @"daily";
        case EKRecurrenceFrequencyWeekly: return @"weekly";
        case EKRecurrenceFrequencyMonthly: return @"monthly";
        case EKRecurrenceFrequencyYearly: return @"yearly";
    }
    return @"unknown";
}

static NSDictionary *RecurrenceJSON(EKRecurrenceRule *rule) {
    NSMutableDictionary *result = [@{
        @"frequency": FrequencyString(rule.frequency),
        @"interval": @(rule.interval),
    } mutableCopy];
    if (rule.daysOfTheWeek.count > 0) {
        NSMutableArray *days = NSMutableArray.array;
        for (EKRecurrenceDayOfWeek *day in rule.daysOfTheWeek) {
            NSMutableDictionary *item = [@{@"day": WeekdayString(day.dayOfTheWeek)} mutableCopy];
            if (day.weekNumber != 0) item[@"week_number"] = @(day.weekNumber);
            [days addObject:item];
        }
        result[@"days_of_week"] = days;
    }
    if (rule.daysOfTheMonth.count > 0) result[@"days_of_month"] = rule.daysOfTheMonth;
    if (rule.monthsOfTheYear.count > 0) result[@"months_of_year"] = rule.monthsOfTheYear;
    if (rule.weeksOfTheYear.count > 0) result[@"weeks_of_year"] = rule.weeksOfTheYear;
    if (rule.daysOfTheYear.count > 0) result[@"days_of_year"] = rule.daysOfTheYear;
    if (rule.setPositions.count > 0) result[@"set_positions"] = rule.setPositions;
    if (rule.recurrenceEnd.endDate != nil) result[@"end"] = @{@"date": ISODateString(rule.recurrenceEnd.endDate)};
    else if (rule.recurrenceEnd.occurrenceCount > 0) result[@"end"] = @{@"count": @(rule.recurrenceEnd.occurrenceCount)};
    return result;
}

static NSArray<NSNumber *> *IntegerArray(NSDictionary *input, NSString *key, NSInteger min, NSInteger max, BOOL rejectZero, NSError **error) {
    NSArray *values = OptionalArray(input, key, error);
    if (values == nil) return nil;
    NSMutableArray<NSNumber *> *result = NSMutableArray.array;
    for (id value in values) {
        if (![value isKindOfClass:NSNumber.class]) {
            if (error) *error = MakeError([NSString stringWithFormat:@"%@ must contain integers.", key]);
            return nil;
        }
        NSInteger number = [value integerValue];
        if (number < min || number > max || (rejectZero && number == 0)) {
            if (error) *error = MakeError([NSString stringWithFormat:@"%@ contains an out-of-range value: %@", key, value]);
            return nil;
        }
        [result addObject:@(number)];
    }
    return result;
}

static EKRecurrenceRule *RecurrenceFromJSON(NSDictionary *input, NSTimeZone *timezone, NSError **error) {
    if (![input isKindOfClass:NSDictionary.class]) {
        if (error) *error = MakeError(@"Each recurrence rule must be an object.");
        return nil;
    }
    NSString *frequencyName = RequiredString(input, @"frequency", error);
    if (frequencyName == nil) return nil;
    NSDictionary *frequencies = @{
        @"daily": @(EKRecurrenceFrequencyDaily), @"weekly": @(EKRecurrenceFrequencyWeekly),
        @"monthly": @(EKRecurrenceFrequencyMonthly), @"yearly": @(EKRecurrenceFrequencyYearly),
    };
    NSNumber *frequencyNumber = frequencies[frequencyName.lowercaseString];
    if (frequencyNumber == nil) {
        if (error) *error = MakeError(@"frequency must be daily, weekly, monthly, or yearly.");
        return nil;
    }
    NSInteger interval = HasKey(input, @"interval") ? [input[@"interval"] integerValue] : 1;
    if (interval < 1) {
        if (error) *error = MakeError(@"recurrence interval must be at least 1.");
        return nil;
    }

    NSMutableArray<EKRecurrenceDayOfWeek *> *days = nil;
    NSArray *dayInputs = OptionalArray(input, @"days_of_week", error);
    if (dayInputs != nil) {
        days = NSMutableArray.array;
        for (id rawDay in dayInputs) {
            if (![rawDay isKindOfClass:NSDictionary.class]) {
                if (error) *error = MakeError(@"days_of_week entries must be objects.");
                return nil;
            }
            NSString *name = RequiredString(rawDay, @"day", error);
            EKWeekday weekday = WeekdayFromString(name);
            if (weekday == 0) {
                if (error) *error = MakeError([NSString stringWithFormat:@"Unknown weekday: %@", name]);
                return nil;
            }
            NSInteger weekNumber = HasKey(rawDay, @"week_number") ? [rawDay[@"week_number"] integerValue] : 0;
            if (weekNumber < -53 || weekNumber > 53) {
                if (error) *error = MakeError(@"week_number must be between -53 and 53.");
                return nil;
            }
            [days addObject:[EKRecurrenceDayOfWeek dayOfWeek:weekday weekNumber:weekNumber]];
        }
    }

    NSArray *monthDays = IntegerArray(input, @"days_of_month", -31, 31, YES, error);
    if (HasKey(input, @"days_of_month") && monthDays == nil) return nil;
    NSArray *months = IntegerArray(input, @"months_of_year", 1, 12, NO, error);
    if (HasKey(input, @"months_of_year") && months == nil) return nil;
    NSArray *weeks = IntegerArray(input, @"weeks_of_year", -53, 53, YES, error);
    if (HasKey(input, @"weeks_of_year") && weeks == nil) return nil;
    NSArray *yearDays = IntegerArray(input, @"days_of_year", -366, 366, YES, error);
    if (HasKey(input, @"days_of_year") && yearDays == nil) return nil;
    NSArray *positions = IntegerArray(input, @"set_positions", -366, 366, YES, error);
    if (HasKey(input, @"set_positions") && positions == nil) return nil;

    EKRecurrenceEnd *recurrenceEnd = nil;
    NSDictionary *end = [input[@"end"] isKindOfClass:NSDictionary.class] ? input[@"end"] : nil;
    if (end != nil) {
        BOOL hasDate = HasKey(end, @"date");
        BOOL hasCount = HasKey(end, @"count");
        if (hasDate == hasCount) {
            if (error) *error = MakeError(@"recurrence end must contain exactly one of date or count.");
            return nil;
        }
        if (hasDate) {
            NSDate *date = DateFromISO(OptionalString(end, @"date"), timezone, error);
            if (date == nil) return nil;
            recurrenceEnd = [EKRecurrenceEnd recurrenceEndWithEndDate:date];
        } else {
            NSInteger count = [end[@"count"] integerValue];
            if (count < 1) {
                if (error) *error = MakeError(@"recurrence end count must be at least 1.");
                return nil;
            }
            recurrenceEnd = [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:(NSUInteger)count];
        }
    }

    @try {
        return [[EKRecurrenceRule alloc] initRecurrenceWithFrequency:[frequencyNumber integerValue]
                                                            interval:interval
                                                       daysOfTheWeek:days
                                                      daysOfTheMonth:monthDays
                                                     monthsOfTheYear:months
                                                      weeksOfTheYear:weeks
                                                       daysOfTheYear:yearDays
                                                        setPositions:positions
                                                                 end:recurrenceEnd];
    } @catch (NSException *exception) {
        if (error) *error = MakeError([NSString stringWithFormat:@"Invalid recurrence rule: %@", exception.reason]);
        return nil;
    }
}

static NSDictionary *AlarmJSON(EKAlarm *alarm) {
    if (alarm.structuredLocation != nil && alarm.proximity != EKAlarmProximityNone) {
        NSMutableDictionary *result = [@{
            @"type": @"location",
            @"proximity": alarm.proximity == EKAlarmProximityEnter ? @"enter" : @"leave",
            @"title": alarm.structuredLocation.title ?: @"",
            @"radius_m": @(alarm.structuredLocation.radius),
        } mutableCopy];
        CLLocation *location = alarm.structuredLocation.geoLocation;
        if (location != nil) {
            result[@"latitude"] = @(location.coordinate.latitude);
            result[@"longitude"] = @(location.coordinate.longitude);
        }
        return result;
    }
    if (alarm.absoluteDate != nil) return @{@"type": @"absolute", @"at": ISODateString(alarm.absoluteDate)};
    return @{@"type": @"relative", @"offset_seconds": @(alarm.relativeOffset)};
}

static EKAlarm *AlarmFromJSON(NSDictionary *input, NSTimeZone *timezone, NSError **error) {
    if (![input isKindOfClass:NSDictionary.class]) {
        if (error) *error = MakeError(@"Each alarm must be an object.");
        return nil;
    }
    NSString *type = RequiredString(input, @"type", error);
    if ([type isEqualToString:@"absolute"]) {
        NSDate *date = DateFromISO(RequiredString(input, @"at", error), timezone, error);
        return date == nil ? nil : [EKAlarm alarmWithAbsoluteDate:date];
    }
    if ([type isEqualToString:@"relative"]) {
        if (![input[@"offset_seconds"] isKindOfClass:NSNumber.class]) {
            if (error) *error = MakeError(@"Relative alarms require numeric offset_seconds.");
            return nil;
        }
        return [EKAlarm alarmWithRelativeOffset:[input[@"offset_seconds"] doubleValue]];
    }
    if ([type isEqualToString:@"location"]) {
        NSString *proximity = RequiredString(input, @"proximity", error);
        NSString *title = RequiredString(input, @"title", error);
        if (proximity == nil || title == nil) return nil;
        if (![proximity isEqualToString:@"enter"] && ![proximity isEqualToString:@"leave"]) {
            if (error) *error = MakeError(@"Location alarm proximity must be enter or leave.");
            return nil;
        }
        if (![input[@"latitude"] isKindOfClass:NSNumber.class] || ![input[@"longitude"] isKindOfClass:NSNumber.class]) {
            if (error) *error = MakeError(@"Location alarms require numeric latitude and longitude.");
            return nil;
        }
        double latitude = [input[@"latitude"] doubleValue];
        double longitude = [input[@"longitude"] doubleValue];
        if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
            if (error) *error = MakeError(@"Location alarm coordinates are out of range.");
            return nil;
        }
        EKStructuredLocation *location = [EKStructuredLocation locationWithTitle:title];
        location.geoLocation = [[CLLocation alloc] initWithLatitude:latitude longitude:longitude];
        location.radius = [input[@"radius_m"] isKindOfClass:NSNumber.class] ? MAX(0, [input[@"radius_m"] doubleValue]) : 0;
        EKAlarm *alarm = [EKAlarm alarmWithRelativeOffset:0];
        alarm.structuredLocation = location;
        alarm.proximity = [proximity isEqualToString:@"enter"] ? EKAlarmProximityEnter : EKAlarmProximityLeave;
        return alarm;
    }
    if (error) *error = MakeError([NSString stringWithFormat:@"Unknown alarm type: %@", type]);
    return nil;
}

static NSDictionary *ReminderJSON(EKReminder *reminder) {
    NSMutableDictionary *result = [@{
        @"id": reminder.calendarItemIdentifier ?: @"",
        @"externalId": reminder.calendarItemExternalIdentifier ?: @"",
        @"title": reminder.title ?: @"",
        @"list": reminder.calendar.title ?: @"",
        @"listId": reminder.calendar.calendarIdentifier ?: @"",
        @"source": reminder.calendar.source.title ?: @"",
        @"sourceId": reminder.calendar.source.sourceIdentifier ?: @"",
        @"writable": @(reminder.calendar.allowsContentModifications),
        @"completed": @(reminder.completed),
        @"priority": @(reminder.priority),
    } mutableCopy];
    if (reminder.notes.length > 0) result[@"notes"] = reminder.notes;
    if (reminder.location.length > 0) result[@"location"] = reminder.location;
    if (reminder.URL != nil) result[@"url"] = reminder.URL.absoluteString;
    if (reminder.timeZone.name.length > 0) result[@"timezone"] = reminder.timeZone.name;
    if (reminder.creationDate != nil) result[@"createdAt"] = ISODateString(reminder.creationDate);
    if (reminder.lastModifiedDate != nil) result[@"modifiedAt"] = ISODateString(reminder.lastModifiedDate);
    if (reminder.completionDate != nil) result[@"completedAt"] = ISODateString(reminder.completionDate);
    NSDictionary *start = ComponentsJSON(reminder.startDateComponents);
    NSDictionary *due = ComponentsJSON(reminder.dueDateComponents);
    if (start != nil) result[@"start"] = start;
    if (due != nil) result[@"due"] = due;
    NSMutableArray *alarms = NSMutableArray.array;
    for (EKAlarm *alarm in reminder.alarms ?: @[]) [alarms addObject:AlarmJSON(alarm)];
    result[@"alarms"] = alarms;
    NSMutableArray *rules = NSMutableArray.array;
    for (EKRecurrenceRule *rule in reminder.recurrenceRules ?: @[]) [rules addObject:RecurrenceJSON(rule)];
    result[@"recurrenceRules"] = rules;
    return result;
}

static NSDictionary *ReminderSummary(EKReminder *reminder) {
    NSMutableDictionary *result = [@{
        @"id": reminder.calendarItemIdentifier ?: @"",
        @"title": reminder.title ?: @"",
        @"list": reminder.calendar.title ?: @"",
        @"listId": reminder.calendar.calendarIdentifier ?: @"",
        @"completed": @(reminder.completed),
    } mutableCopy];
    if (reminder.lastModifiedDate != nil) result[@"modifiedAt"] = ISODateString(reminder.lastModifiedDate);
    return result;
}

static NSDictionary *CompletionResult(EKReminder *reminder, BOOL requestedCompleted) {
    NSMutableDictionary *result = [ReminderJSON(reminder) mutableCopy];
    result[@"requestedCompleted"] = @(requestedCompleted);
    if (requestedCompleted && !reminder.completed && reminder.hasRecurrenceRules) {
        result[@"completionOutcome"] = @"advanced_to_next_occurrence";
    } else if (requestedCompleted) {
        result[@"completionOutcome"] = @"completed";
    } else {
        result[@"completionOutcome"] = @"reopened";
    }
    return result;
}

static NSDictionary *ReminderSnapshot(EKReminder *reminder) {
    return @{
        @"id": reminder.calendarItemIdentifier ?: @"",
        @"externalId": reminder.calendarItemExternalIdentifier ?: @"",
        @"listId": reminder.calendar.calendarIdentifier ?: @"",
        @"modifiedAt": reminder.lastModifiedDate == nil ? NSNull.null : ISODateString(reminder.lastModifiedDate),
    };
}

static NSArray *SortedSnapshots(NSArray<EKReminder *> *reminders) {
    NSMutableArray *snapshots = NSMutableArray.array;
    for (EKReminder *reminder in reminders) [snapshots addObject:ReminderSnapshot(reminder)];
    [snapshots sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"id"] compare:right[@"id"]];
    }];
    return snapshots;
}

static NSArray<EKReminder *> *FetchReminders(EKEventStore *store, NSPredicate *predicate) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSArray<EKReminder *> *result = @[];
    [store fetchRemindersMatchingPredicate:predicate completion:^(NSArray<EKReminder *> *reminders) {
        result = reminders ?: @[];
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return result;
}

static EKReminder *ReminderFromInput(NSDictionary *input, EKEventStore *store, NSError **error) {
    NSString *identifier = OptionalString(input, @"id");
    if (identifier.length > 0) {
        EKCalendarItem *item = [store calendarItemWithIdentifier:identifier];
        if ([item isKindOfClass:EKReminder.class]) return (EKReminder *)item;
    }

    NSString *externalId = OptionalString(input, @"external_id");
    if (externalId.length > 0) {
        NSArray<EKCalendarItem *> *items = [store calendarItemsWithExternalIdentifier:externalId];
        NSMutableArray<EKReminder *> *matches = NSMutableArray.array;
        for (EKCalendarItem *item in items) {
            if (![item isKindOfClass:EKReminder.class]) continue;
            [matches addObject:(EKReminder *)item];
        }
        if (matches.count == 1) return matches.firstObject;
        NSString *listId = OptionalString(input, @"current_list_id") ?: OptionalString(input, @"list_id");
        if (listId.length > 0) {
            NSIndexSet *otherLists = [matches indexesOfObjectsPassingTest:^BOOL(EKReminder *reminder, NSUInteger idx, BOOL *stop) {
                (void)idx;
                (void)stop;
                return ![reminder.calendar.calendarIdentifier isEqualToString:listId];
            }];
            [matches removeObjectsAtIndexes:otherLists];
        }
        if (matches.count == 1) return matches.firstObject;
        if (matches.count > 1) {
            if (error) *error = MakeError(@"external_id matched more than one reminder. Supply list_id to disambiguate.");
            return nil;
        }
    }
    if (error) *error = MakeError([NSString stringWithFormat:@"Reminder not found for id/external_id: %@. List reminders again and retry.", identifier ?: externalId ?: @"(missing)"]);
    return nil;
}

static NSArray<EKReminder *> *RemindersFromIds(NSArray *ids, EKEventStore *store, NSError **error) {
    if (![ids isKindOfClass:NSArray.class] || ids.count == 0 || ids.count > 500) {
        if (error) *error = MakeError(@"ids must contain between 1 and 500 reminder identifiers.");
        return nil;
    }
    NSMutableSet *seen = NSMutableSet.set;
    NSMutableArray<EKReminder *> *reminders = NSMutableArray.array;
    for (id rawId in ids) {
        if (![rawId isKindOfClass:NSString.class] || [rawId length] == 0 || [seen containsObject:rawId]) {
            if (error) *error = MakeError(@"ids must contain unique, non-empty strings.");
            return nil;
        }
        [seen addObject:rawId];
        NSError *lookupError = nil;
        EKReminder *reminder = ReminderFromInput(@{@"id": rawId}, store, &lookupError);
        if (reminder == nil) {
            if (error) *error = lookupError;
            return nil;
        }
        [reminders addObject:reminder];
    }
    return reminders;
}

static BOOL WritableReminder(EKReminder *reminder, NSError **error) {
    if (reminder.calendar.allowsContentModifications) return YES;
    if (error) *error = MakeError([NSString stringWithFormat:@"Reminder '%@' is in read-only list '%@'.", reminder.title, reminder.calendar.title]);
    return NO;
}

static BOOL ApplyReminderFields(EKReminder *reminder, NSDictionary *input, EKEventStore *store, BOOL creating, NSError **error) {
    NSTimeZone *timezone = TimeZoneFromInput(input, error);
    if (timezone == nil) return NO;

    if (creating || HasKey(input, @"title")) {
        NSString *title = RequiredString(input, @"title", error);
        if (title == nil) return NO;
        reminder.title = title;
    }
    if (creating || HasKey(input, @"list") || HasKey(input, @"list_id")) {
        EKCalendar *calendar = CalendarFromInput(input, store, YES, error);
        if (calendar == nil) return NO;
        if (!calendar.allowsContentModifications) {
            if (error) *error = MakeError([NSString stringWithFormat:@"Reminder list '%@' is read-only.", calendar.title]);
            return NO;
        }
        reminder.calendar = calendar;
    }

    if ([input[@"clear_notes"] boolValue]) reminder.notes = nil;
    if (HasKey(input, @"notes")) reminder.notes = OptionalString(input, @"notes");
    if ([input[@"clear_location"] boolValue]) reminder.location = nil;
    if (HasKey(input, @"location")) reminder.location = OptionalString(input, @"location");
    if ([input[@"clear_url"] boolValue]) reminder.URL = nil;
    if (HasKey(input, @"url")) {
        NSString *rawURL = OptionalString(input, @"url");
        NSURL *url = [NSURL URLWithString:rawURL];
        if (url == nil || url.scheme.length == 0) {
            if (error) *error = MakeError(@"url must be an absolute URL with a scheme.");
            return NO;
        }
        reminder.URL = url;
    }
    if (HasKey(input, @"priority")) {
        NSInteger priority = [input[@"priority"] integerValue];
        if (priority < 0 || priority > 9) {
            if (error) *error = MakeError(@"priority must be between 0 and 9.");
            return NO;
        }
        reminder.priority = priority;
    }
    if ([input[@"clear_start"] boolValue]) reminder.startDateComponents = nil;
    if (HasKey(input, @"start")) {
        reminder.startDateComponents = DateComponentsFromString(OptionalString(input, @"start"), timezone, error);
        if (reminder.startDateComponents == nil) return NO;
    }
    if ([input[@"clear_due"] boolValue]) reminder.dueDateComponents = nil;
    if (HasKey(input, @"due")) {
        reminder.dueDateComponents = DateComponentsFromString(OptionalString(input, @"due"), timezone, error);
        if (reminder.dueDateComponents == nil) return NO;
    }
    reminder.timeZone = timezone;

    if ([input[@"clear_alarms"] boolValue]) reminder.alarms = @[];
    if (HasKey(input, @"alarms")) {
        NSArray *alarmInputs = OptionalArray(input, @"alarms", error);
        if (alarmInputs == nil) return NO;
        NSMutableArray *alarms = NSMutableArray.array;
        for (id alarmInput in alarmInputs) {
            EKAlarm *alarm = AlarmFromJSON(alarmInput, timezone, error);
            if (alarm == nil) return NO;
            [alarms addObject:alarm];
        }
        reminder.alarms = alarms;
    }

    if ([input[@"clear_recurrence"] boolValue]) reminder.recurrenceRules = @[];
    if (HasKey(input, @"recurrence_rules")) {
        NSArray *ruleInputs = OptionalArray(input, @"recurrence_rules", error);
        if (ruleInputs == nil) return NO;
        NSMutableArray *rules = NSMutableArray.array;
        for (id ruleInput in ruleInputs) {
            EKRecurrenceRule *rule = RecurrenceFromJSON(ruleInput, timezone, error);
            if (rule == nil) return NO;
            [rules addObject:rule];
        }
        reminder.recurrenceRules = rules;
    }
    return YES;
}

static BOOL CommitStore(EKEventStore *store, NSString *operation, NSError **error) {
    NSError *commitError = nil;
    if ([store commit:&commitError]) return YES;
    [store reset];
    if (error) *error = WrapError(operation, commitError);
    return NO;
}

static NSDictionary *RunSelfTests(NSError **error) {
    NSTimeZone *zone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
    NSError *testError = nil;
    NSDateComponents *allDay = DateComponentsFromString(@"2026-08-20", zone, &testError);
    if (allDay == nil || allDay.hour != NSDateComponentUndefined || ![[ComponentsJSON(allDay) objectForKey:@"date"] isEqualToString:@"2026-08-20"]) {
        if (error) *error = testError ?: MakeError(@"All-day date round-trip failed.");
        return nil;
    }
    testError = nil;
    if (DateComponentsFromString(@"2026-02-30", zone, &testError) != nil || testError == nil) {
        if (error) *error = MakeError(@"Invalid calendar date validation failed.");
        return nil;
    }
    testError = nil;
    NSDictionary *ruleInput = @{
        @"frequency": @"monthly",
        @"interval": @2,
        @"days_of_week": @[@{@"day": @"tuesday", @"week_number": @(-1)}],
        @"end": @{@"count": @5},
    };
    EKRecurrenceRule *rule = RecurrenceFromJSON(ruleInput, zone, &testError);
    NSDictionary *ruleOutput = rule == nil ? nil : RecurrenceJSON(rule);
    if (ruleOutput == nil || ![ruleOutput[@"frequency"] isEqualToString:@"monthly"] || [ruleOutput[@"interval"] integerValue] != 2) {
        if (error) *error = testError ?: MakeError(@"Recurrence rule round-trip failed.");
        return nil;
    }
    testError = nil;
    NSDictionary *alarmInput = @{
        @"type": @"location", @"proximity": @"enter", @"title": @"Office",
        @"latitude": @31.2304, @"longitude": @121.4737, @"radius_m": @200,
    };
    EKAlarm *alarm = AlarmFromJSON(alarmInput, zone, &testError);
    NSDictionary *alarmOutput = alarm == nil ? nil : AlarmJSON(alarm);
    if (alarmOutput == nil || ![alarmOutput[@"type"] isEqualToString:@"location"] || ![alarmOutput[@"proximity"] isEqualToString:@"enter"]) {
        if (error) *error = testError ?: MakeError(@"Location alarm round-trip failed.");
        return nil;
    }
    return @{@"passed": @4, @"date": ComponentsJSON(allDay), @"recurrence": ruleOutput, @"alarm": alarmOutput};
}

static id PerformAction(NSString *action, NSDictionary *input, EKEventStore *store, NSError **error) {
    if ([action isEqualToString:@"list_sources"]) {
        NSMutableArray *output = NSMutableArray.array;
        for (EKSource *source in store.sources) {
            if ([source calendarsForEntityType:EKEntityTypeReminder].count > 0 || source.sourceType == EKSourceTypeLocal || source.sourceType == EKSourceTypeCalDAV || source.sourceType == EKSourceTypeExchange) {
                [output addObject:SourceJSON(source)];
            }
        }
        [output sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
        }];
        return output;
    }

    if ([action isEqualToString:@"list_lists"]) {
        NSMutableArray *output = NSMutableArray.array;
        for (EKCalendar *calendar in SortedCalendars(store)) [output addObject:CalendarJSON(calendar, store)];
        return output;
    }

    if ([action isEqualToString:@"list_reminders"]) {
        NSError *selectionError = nil;
        NSArray<EKCalendar *> *calendars = SelectedCalendars(input, store, &selectionError);
        if (selectionError != nil) { if (error) *error = selectionError; return nil; }
        NSPredicate *predicate = [store predicateForRemindersInCalendars:calendars];
        NSMutableArray<EKReminder *> *reminders = [FetchReminders(store, predicate) mutableCopy];
        if (![input[@"include_completed"] boolValue]) {
            NSIndexSet *completed = [reminders indexesOfObjectsPassingTest:^BOOL(EKReminder *reminder, NSUInteger idx, BOOL *stop) {
                (void)idx;
                (void)stop;
                return reminder.completed;
            }];
            [reminders removeObjectsAtIndexes:completed];
        }
        [reminders sortUsingComparator:^NSComparisonResult(EKReminder *left, EKReminder *right) {
            NSDate *a = DateFromComponents(left.dueDateComponents);
            NSDate *b = DateFromComponents(right.dueDateComponents);
            if (a != nil && b != nil) {
                NSComparisonResult result = [a compare:b];
                if (result != NSOrderedSame) return result;
            } else if (a != nil) return NSOrderedAscending;
            else if (b != nil) return NSOrderedDescending;
            return [left.title localizedCaseInsensitiveCompare:right.title];
        }];
        NSMutableArray *output = NSMutableArray.array;
        for (EKReminder *reminder in reminders) [output addObject:ReminderJSON(reminder)];
        return output;
    }

    if ([action isEqualToString:@"get_reminder"]) {
        EKReminder *reminder = ReminderFromInput(input, store, error);
        return reminder == nil ? nil : ReminderJSON(reminder);
    }

    if ([action isEqualToString:@"create_reminder"]) {
        EKReminder *reminder = [EKReminder reminderWithEventStore:store];
        if (!ApplyReminderFields(reminder, input, store, YES, error)) return nil;
        NSError *saveError = nil;
        if (![store saveReminder:reminder commit:YES error:&saveError]) {
            if (error) *error = WrapError(@"Unable to create reminder; the selected account may not support the requested alarm, location, or recurrence rule", saveError);
            return nil;
        }
        [reminder refresh];
        return ReminderJSON(reminder);
    }

    if ([action isEqualToString:@"update_reminder"]) {
        EKReminder *reminder = ReminderFromInput(input, store, error);
        if (reminder == nil || !WritableReminder(reminder, error)) return nil;
        if (!ApplyReminderFields(reminder, input, store, NO, error)) return nil;
        NSError *saveError = nil;
        if (![store saveReminder:reminder commit:YES error:&saveError]) {
            if (error) *error = WrapError(@"Unable to update reminder; the selected account may not support the requested alarm, location, or recurrence rule", saveError);
            return nil;
        }
        [reminder refresh];
        return ReminderJSON(reminder);
    }

    if ([action isEqualToString:@"set_completed"]) {
        EKReminder *reminder = ReminderFromInput(input, store, error);
        if (reminder == nil || !WritableReminder(reminder, error)) return nil;
        if (![input[@"completed"] isKindOfClass:NSNumber.class]) {
            if (error) *error = MakeError(@"completed must be true or false.");
            return nil;
        }
        reminder.completed = [input[@"completed"] boolValue];
        NSError *saveError = nil;
        if (![store saveReminder:reminder commit:YES error:&saveError]) {
            if (error) *error = WrapError(@"Unable to change reminder completion", saveError);
            return nil;
        }
        [reminder refresh];
        return CompletionResult(reminder, [input[@"completed"] boolValue]);
    }

    if ([action isEqualToString:@"delete_reminder"]) {
        if (![input[@"confirm"] boolValue]) {
            if (error) *error = MakeError(@"Single-reminder deletion requires confirm=true.");
            return nil;
        }
        EKReminder *reminder = ReminderFromInput(input, store, error);
        if (reminder == nil || !WritableReminder(reminder, error)) return nil;
        NSDictionary *deleted = ReminderSummary(reminder);
        NSError *removeError = nil;
        if (![store removeReminder:reminder commit:YES error:&removeError]) {
            if (error) *error = WrapError(@"Unable to delete reminder", removeError);
            return nil;
        }
        return deleted;
    }

    if ([action isEqualToString:@"create_list"]) {
        NSString *name = RequiredString(input, @"name", error);
        EKSource *source = SourceFromInput(input, store, error);
        if (name == nil || source == nil) return nil;
        EKCalendar *calendar = [EKCalendar calendarForEntityType:EKEntityTypeReminder eventStore:store];
        calendar.title = name;
        calendar.source = source;
        if (!ApplyCalendarColor(calendar, OptionalString(input, @"color"), error)) return nil;
        NSError *saveError = nil;
        if (![store saveCalendar:calendar commit:YES error:&saveError]) {
            if (error) *error = WrapError(@"Unable to create reminder list; the selected account may not allow list creation", saveError);
            return nil;
        }
        return CalendarJSON(calendar, store);
    }

    if ([action isEqualToString:@"update_list"]) {
        EKCalendar *calendar = CalendarFromInput(input, store, NO, error);
        if (calendar == nil) return nil;
        if (calendar.isImmutable) {
            if (error) *error = MakeError([NSString stringWithFormat:@"Reminder list '%@' is immutable.", calendar.title]);
            return nil;
        }
        if (HasKey(input, @"name")) {
            NSString *name = RequiredString(input, @"name", error);
            if (name == nil) return nil;
            calendar.title = name;
        }
        if (!ApplyCalendarColor(calendar, OptionalString(input, @"color"), error)) return nil;
        if (!HasKey(input, @"name") && !HasKey(input, @"color")) {
            if (error) *error = MakeError(@"Provide name or color to update.");
            return nil;
        }
        NSError *saveError = nil;
        if (![store saveCalendar:calendar commit:YES error:&saveError]) {
            if (error) *error = WrapError(@"Unable to update reminder list", saveError);
            return nil;
        }
        return CalendarJSON(calendar, store);
    }

    if ([action isEqualToString:@"inspect_list_delete"]) {
        EKCalendar *calendar = CalendarFromInput(input, store, NO, error);
        if (calendar == nil) return nil;
        if (calendar.isImmutable) {
            if (error) *error = MakeError([NSString stringWithFormat:@"Reminder list '%@' is immutable and cannot be deleted.", calendar.title]);
            return nil;
        }
        if ((calendar.allowedEntityTypes & EKEntityMaskEvent) != 0) {
            if (error) *error = MakeError(@"Refusing to delete a mixed event/reminder calendar because the plugin has Reminders access only.");
            return nil;
        }
        NSArray<EKReminder *> *reminders = FetchReminders(store, [store predicateForRemindersInCalendars:@[calendar]]);
        NSMutableArray *items = NSMutableArray.array;
        for (EKReminder *reminder in reminders) [items addObject:ReminderSummary(reminder)];
        return @{@"list": CalendarJSON(calendar, store), @"items": items, @"count": @(items.count), @"snapshots": SortedSnapshots(reminders)};
    }

    if ([action isEqualToString:@"delete_list"]) {
        EKCalendar *calendar = CalendarFromInput(input, store, NO, error);
        if (calendar == nil) return nil;
        if (calendar.isImmutable || (calendar.allowedEntityTypes & EKEntityMaskEvent) != 0) {
            if (error) *error = MakeError(@"The selected list is immutable or also contains events, so it cannot be safely deleted.");
            return nil;
        }
        NSArray<EKReminder *> *reminders = FetchReminders(store, [store predicateForRemindersInCalendars:@[calendar]]);
        NSArray *expected = OptionalArray(input, @"expected_snapshots", error);
        if (expected == nil || ![SortedSnapshots(reminders) isEqual:expected]) {
            if (error) *error = MakeError(@"The list changed after preview. Preview the deletion again.");
            return nil;
        }
        NSDictionary *deleted = CalendarJSON(calendar, store);
        NSError *removeError = nil;
        if (![store removeCalendar:calendar commit:YES error:&removeError]) {
            if (error) *error = WrapError(@"Unable to delete reminder list", removeError);
            return nil;
        }
        return @{@"deletedList": deleted, @"deletedReminderCount": @(reminders.count)};
    }

    if ([action isEqualToString:@"inspect_reminders_delete"]) {
        NSArray<EKReminder *> *reminders = RemindersFromIds(input[@"ids"], store, error);
        if (reminders == nil) return nil;
        NSMutableArray *items = NSMutableArray.array;
        for (EKReminder *reminder in reminders) [items addObject:ReminderSummary(reminder)];
        return @{@"items": items, @"count": @(items.count), @"snapshots": SortedSnapshots(reminders)};
    }

    if ([action isEqualToString:@"delete_reminders"]) {
        NSArray<EKReminder *> *reminders = RemindersFromIds(input[@"ids"], store, error);
        if (reminders == nil) return nil;
        NSArray *expected = OptionalArray(input, @"expected_snapshots", error);
        if (expected == nil || ![SortedSnapshots(reminders) isEqual:expected]) {
            if (error) *error = MakeError(@"One or more reminders changed after preview. Preview the deletion again.");
            return nil;
        }
        for (EKReminder *reminder in reminders) if (!WritableReminder(reminder, error)) return nil;
        for (EKReminder *reminder in reminders) {
            NSError *removeError = nil;
            if (![store removeReminder:reminder commit:NO error:&removeError]) {
                [store reset];
                if (error) *error = WrapError([NSString stringWithFormat:@"Unable to stage deletion of '%@'", reminder.title], removeError);
                return nil;
            }
        }
        if (!CommitStore(store, @"Unable to commit reminder deletions", error)) return nil;
        NSMutableArray *deleted = NSMutableArray.array;
        for (EKReminder *reminder in reminders) [deleted addObject:ReminderSummary(reminder)];
        return @{@"deleted": deleted, @"count": @(deleted.count)};
    }

    if ([action isEqualToString:@"bulk_set_completed"]) {
        NSArray<EKReminder *> *reminders = RemindersFromIds(input[@"ids"], store, error);
        if (reminders == nil || ![input[@"completed"] isKindOfClass:NSNumber.class]) {
            if (reminders != nil && error) *error = MakeError(@"completed must be true or false.");
            return nil;
        }
        for (EKReminder *reminder in reminders) if (!WritableReminder(reminder, error)) return nil;
        BOOL completed = [input[@"completed"] boolValue];
        for (EKReminder *reminder in reminders) {
            reminder.completed = completed;
            NSError *saveError = nil;
            if (![store saveReminder:reminder commit:NO error:&saveError]) {
                [store reset];
                if (error) *error = WrapError([NSString stringWithFormat:@"Unable to stage completion change for '%@'", reminder.title], saveError);
                return nil;
            }
        }
        if (!CommitStore(store, @"Unable to commit completion changes", error)) return nil;
        NSMutableArray *updated = NSMutableArray.array;
        for (EKReminder *reminder in reminders) {
            [reminder refresh];
            [updated addObject:CompletionResult(reminder, completed)];
        }
        return updated;
    }

    if ([action isEqualToString:@"bulk_move"]) {
        NSArray<EKReminder *> *reminders = RemindersFromIds(input[@"ids"], store, error);
        EKCalendar *target = CalendarFromInput(input, store, NO, error);
        if (reminders == nil || target == nil) return nil;
        if (!target.allowsContentModifications) {
            if (error) *error = MakeError([NSString stringWithFormat:@"Target list '%@' is read-only.", target.title]);
            return nil;
        }
        for (EKReminder *reminder in reminders) if (!WritableReminder(reminder, error)) return nil;
        for (EKReminder *reminder in reminders) {
            reminder.calendar = target;
            NSError *saveError = nil;
            if (![store saveReminder:reminder commit:NO error:&saveError]) {
                [store reset];
                if (error) *error = WrapError([NSString stringWithFormat:@"Unable to stage move for '%@'", reminder.title], saveError);
                return nil;
            }
        }
        if (!CommitStore(store, @"Unable to commit reminder moves", error)) return nil;
        NSMutableArray *updated = NSMutableArray.array;
        for (EKReminder *reminder in reminders) {
            [reminder refresh];
            [updated addObject:ReminderJSON(reminder)];
        }
        return updated;
    }

    if (error) *error = MakeError([NSString stringWithFormat:@"Unknown action: %@", action]);
    return nil;
}

static void WriteJSON(NSDictionary *object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:&error];
    if (data != nil) {
        [[NSFileHandle fileHandleWithStandardOutput] writeData:data];
        [[NSFileHandle fileHandleWithStandardOutput] writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    } else {
        fprintf(stderr, "Failed to encode JSON: %s\n", error.localizedDescription.UTF8String);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argc;
        (void)argv;
        if (@available(macOS 14.0, *)) {
            NSError *error = nil;
            NSData *inputData = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
            NSDictionary *input = [NSJSONSerialization JSONObjectWithData:inputData options:0 error:&error];
            if (![input isKindOfClass:NSDictionary.class] || ![input[@"action"] isKindOfClass:NSString.class]) {
                WriteJSON(@{@"ok": @NO, @"error": error.localizedDescription ?: @"Expected a JSON object containing an action."});
                return 1;
            }
            if ([input[@"action"] isEqualToString:@"self_test"]) {
                NSDictionary *result = RunSelfTests(&error);
                if (result == nil) {
                    WriteJSON(@{@"ok": @NO, @"error": error.localizedDescription ?: @"Native self-test failed."});
                    return 1;
                }
                WriteJSON(@{@"ok": @YES, @"data": result});
                return 0;
            }
            EKEventStore *store = EKEventStore.new;
            if (!RequestReminderAccess(store, &error)) {
                WriteJSON(@{@"ok": @NO, @"error": error.localizedDescription ?: @"Unable to access Reminders."});
                return 1;
            }
            id result = PerformAction(input[@"action"], input, store, &error);
            if (result == nil) {
                WriteJSON(@{@"ok": @NO, @"error": error.localizedDescription ?: @"Apple Reminders operation failed."});
                return 1;
            }
            WriteJSON(@{@"ok": @YES, @"data": result});
            return 0;
        }
        WriteJSON(@{@"ok": @NO, @"error": @"Apple Reminders plugin 0.2.0 requires macOS 14 or newer."});
        return 1;
    }
}
