#import <EventKit/EventKit.h>
#import <Foundation/Foundation.h>

static NSString *const ErrorDomain = @"CodexAppleReminders";

static NSError *MakeError(NSString *message) {
    return [NSError errorWithDomain:ErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
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

static BOOL RequestReminderAccess(EKEventStore *store, NSError **error) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL granted = NO;
    __block NSError *accessError = nil;

    void (^completion)(BOOL, NSError *) = ^(BOOL allowed, NSError *requestError) {
        granted = allowed;
        accessError = requestError;
        dispatch_semaphore_signal(semaphore);
    };

    if (@available(macOS 14.0, *)) {
        [store requestFullAccessToRemindersWithCompletion:completion];
    } else {
        [store requestAccessToEntityType:EKEntityTypeReminder completion:completion];
    }

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    if (accessError != nil) {
        if (error) *error = accessError;
        return NO;
    }
    if (!granted) {
        if (error) *error = MakeError(@"Reminders access was denied. Enable it in System Settings > Privacy & Security > Reminders.");
        return NO;
    }
    return YES;
}

static NSArray<EKCalendar *> *SortedCalendars(EKEventStore *store) {
    return [[store calendarsForEntityType:EKEntityTypeReminder] sortedArrayUsingComparator:^NSComparisonResult(EKCalendar *left, EKCalendar *right) {
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];
}

static NSError *MissingListError(NSString *name, EKEventStore *store) {
    NSArray *names = [SortedCalendars(store) valueForKey:@"title"];
    return MakeError([NSString stringWithFormat:@"Reminder list '%@' was not found or is read-only. Available lists: %@", name, [names componentsJoinedByString:@", "]]);
}

static NSArray<EKCalendar *> *SelectedCalendars(NSString *name, EKEventStore *store, NSError **error) {
    if (name.length == 0) return nil;
    NSMutableArray<EKCalendar *> *matches = NSMutableArray.array;
    for (EKCalendar *calendar in [store calendarsForEntityType:EKEntityTypeReminder]) {
        if ([calendar.title caseInsensitiveCompare:name] == NSOrderedSame) [matches addObject:calendar];
    }
    if (matches.count == 0) {
        if (error) *error = MissingListError(name, store);
        return nil;
    }
    return matches;
}

static EKCalendar *WritableCalendar(NSString *name, EKEventStore *store, NSError **error) {
    if (name.length > 0) {
        for (EKCalendar *calendar in [store calendarsForEntityType:EKEntityTypeReminder]) {
            if ([calendar.title caseInsensitiveCompare:name] == NSOrderedSame && calendar.allowsContentModifications) return calendar;
        }
        if (error) *error = MissingListError(name, store);
        return nil;
    }

    EKCalendar *calendar = store.defaultCalendarForNewReminders;
    if (calendar == nil || !calendar.allowsContentModifications) {
        if (error) *error = MakeError(@"No writable default Reminders list is available.");
        return nil;
    }
    return calendar;
}

static NSString *ISODateString(NSDate *date) {
    NSISO8601DateFormatter *formatter = NSISO8601DateFormatter.new;
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter stringFromDate:date];
}

static NSDate *DateFromDueComponents(NSDateComponents *components) {
    if (components == nil) return nil;
    NSCalendar *calendar = components.calendar ?: [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = components.timeZone ?: NSTimeZone.localTimeZone;
    return [calendar dateFromComponents:components];
}

static NSDateComponents *DueComponents(NSString *raw, NSString *timezoneName, NSError **error) {
    NSTimeZone *timezone = timezoneName.length > 0 ? [NSTimeZone timeZoneWithName:timezoneName] : NSTimeZone.localTimeZone;
    if (timezone == nil) {
        if (error) *error = MakeError([NSString stringWithFormat:@"Unknown timezone: %@", timezoneName]);
        return nil;
    }

    NSRegularExpression *dateOnly = [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2}$" options:0 error:nil];
    if ([dateOnly firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)] != nil) {
        NSArray<NSString *> *parts = [raw componentsSeparatedByString:@"-"];
        if (parts.count != 3) {
            if (error) *error = MakeError([NSString stringWithFormat:@"Invalid due date: %@", raw]);
            return nil;
        }
        NSDateComponents *components = NSDateComponents.new;
        components.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        components.timeZone = timezone;
        components.year = parts[0].integerValue;
        components.month = parts[1].integerValue;
        components.day = parts[2].integerValue;
        return components;
    }

    NSISO8601DateFormatter *fractional = NSISO8601DateFormatter.new;
    fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSISO8601DateFormatter *normal = NSISO8601DateFormatter.new;
    normal.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSDate *date = [fractional dateFromString:raw] ?: [normal dateFromString:raw];
    if (date == nil) {
        if (error) *error = MakeError(@"Invalid due date. Use YYYY-MM-DD or an RFC 3339 timestamp.");
        return nil;
    }

    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = timezone;
    NSDateComponents *components = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond) fromDate:date];
    components.calendar = calendar;
    components.timeZone = timezone;
    return components;
}

static NSDictionary *CalendarJSON(EKCalendar *calendar, EKEventStore *store) {
    return @{
        @"id": calendar.calendarIdentifier ?: @"",
        @"name": calendar.title ?: @"",
        @"source": calendar.source.title ?: @"",
        @"writable": @(calendar.allowsContentModifications),
        @"isDefault": @([store.defaultCalendarForNewReminders.calendarIdentifier isEqualToString:calendar.calendarIdentifier]),
    };
}

static NSDictionary *ReminderJSON(EKReminder *reminder) {
    NSMutableDictionary *result = [@{
        @"id": reminder.calendarItemIdentifier ?: @"",
        @"title": reminder.title ?: @"",
        @"list": reminder.calendar.title ?: @"",
        @"completed": @(reminder.completed),
        @"priority": @(reminder.priority),
    } mutableCopy];

    if (reminder.notes.length > 0) result[@"notes"] = reminder.notes;
    if (reminder.completionDate != nil) result[@"completedAt"] = ISODateString(reminder.completionDate);
    NSDateComponents *due = reminder.dueDateComponents;
    if (due != nil) {
        NSMutableDictionary *dueJSON = [@{
            @"year": @(due.year),
            @"month": @(due.month),
            @"day": @(due.day),
            @"allDay": @(due.hour == NSDateComponentUndefined),
        } mutableCopy];
        if (due.hour != NSDateComponentUndefined) dueJSON[@"hour"] = @(due.hour);
        if (due.minute != NSDateComponentUndefined) dueJSON[@"minute"] = @(due.minute);
        if (due.second != NSDateComponentUndefined) dueJSON[@"second"] = @(due.second);
        if (due.timeZone.name.length > 0) dueJSON[@"timezone"] = due.timeZone.name;
        NSDate *date = DateFromDueComponents(due);
        if (date != nil && due.hour != NSDateComponentUndefined) dueJSON[@"dateTime"] = ISODateString(date);
        result[@"due"] = dueJSON;
    }
    return result;
}

static EKReminder *ReminderFromInput(NSDictionary *input, EKEventStore *store, NSError **error) {
    NSString *identifier = RequiredString(input, @"id", error);
    if (identifier == nil) return nil;
    EKCalendarItem *item = [store calendarItemWithIdentifier:identifier];
    if (![item isKindOfClass:EKReminder.class]) {
        if (error) *error = MakeError([NSString stringWithFormat:@"Reminder not found for id: %@. List reminders again and retry with the current id.", identifier]);
        return nil;
    }
    return (EKReminder *)item;
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

static id PerformAction(NSString *action, NSDictionary *input, EKEventStore *store, NSError **error) {
    if ([action isEqualToString:@"list_lists"]) {
        NSMutableArray *output = NSMutableArray.array;
        for (EKCalendar *calendar in SortedCalendars(store)) [output addObject:CalendarJSON(calendar, store)];
        return output;
    }

    if ([action isEqualToString:@"list_reminders"]) {
        NSError *selectionError = nil;
        NSArray<EKCalendar *> *calendars = SelectedCalendars(OptionalString(input, @"list"), store, &selectionError);
        if (selectionError != nil) { if (error) *error = selectionError; return nil; }
        NSPredicate *predicate = [store predicateForRemindersInCalendars:calendars];
        NSMutableArray<EKReminder *> *reminders = [FetchReminders(store, predicate) mutableCopy];

        BOOL includeCompleted = [input[@"include_completed"] boolValue];
        NSString *search = OptionalString(input, @"search");
        NSIndexSet *remove = [reminders indexesOfObjectsPassingTest:^BOOL(EKReminder *reminder, NSUInteger idx, BOOL *stop) {
            if (!includeCompleted && reminder.completed) return YES;
            if (search.length > 0) {
                BOOL titleMatches = [reminder.title rangeOfString:search options:NSCaseInsensitiveSearch].location != NSNotFound;
                BOOL notesMatch = [reminder.notes rangeOfString:search options:NSCaseInsensitiveSearch].location != NSNotFound;
                return !(titleMatches || notesMatch);
            }
            return NO;
        }];
        [reminders removeObjectsAtIndexes:remove];
        [reminders sortUsingComparator:^NSComparisonResult(EKReminder *left, EKReminder *right) {
            NSDate *a = DateFromDueComponents(left.dueDateComponents);
            NSDate *b = DateFromDueComponents(right.dueDateComponents);
            if (a != nil && b != nil) {
                NSComparisonResult result = [a compare:b];
                return result == NSOrderedSame ? [left.title localizedCaseInsensitiveCompare:right.title] : result;
            }
            if (a != nil) return NSOrderedAscending;
            if (b != nil) return NSOrderedDescending;
            return [left.title localizedCaseInsensitiveCompare:right.title];
        }];
        NSMutableArray *output = NSMutableArray.array;
        for (EKReminder *reminder in reminders) [output addObject:ReminderJSON(reminder)];
        return output;
    }

    if ([action isEqualToString:@"create_reminder"]) {
        NSString *title = RequiredString(input, @"title", error);
        if (title == nil) return nil;
        EKCalendar *calendar = WritableCalendar(OptionalString(input, @"list"), store, error);
        if (calendar == nil) return nil;
        EKReminder *reminder = [EKReminder reminderWithEventStore:store];
        reminder.title = title;
        reminder.calendar = calendar;
        reminder.notes = OptionalString(input, @"notes");
        if ([input[@"priority"] isKindOfClass:NSNumber.class]) reminder.priority = [input[@"priority"] integerValue];
        NSString *due = OptionalString(input, @"due");
        if (due != nil) {
            reminder.dueDateComponents = DueComponents(due, OptionalString(input, @"timezone"), error);
            if (reminder.dueDateComponents == nil) return nil;
        }
        if (![store saveReminder:reminder commit:YES error:error]) return nil;
        return ReminderJSON(reminder);
    }

    if ([action isEqualToString:@"update_reminder"]) {
        EKReminder *reminder = ReminderFromInput(input, store, error);
        if (reminder == nil) return nil;
        if (input[@"title"] != nil) {
            NSString *title = RequiredString(input, @"title", error);
            if (title == nil) return nil;
            reminder.title = title;
        }
        if (input[@"notes"] != nil) reminder.notes = OptionalString(input, @"notes") ?: @"";
        NSString *listName = OptionalString(input, @"list");
        if (listName != nil) {
            reminder.calendar = WritableCalendar(listName, store, error);
            if (reminder.calendar == nil) return nil;
        }
        if ([input[@"clear_due"] boolValue]) reminder.dueDateComponents = nil;
        NSString *due = OptionalString(input, @"due");
        if (due != nil) {
            reminder.dueDateComponents = DueComponents(due, OptionalString(input, @"timezone"), error);
            if (reminder.dueDateComponents == nil) return nil;
        }
        if ([input[@"priority"] isKindOfClass:NSNumber.class]) reminder.priority = [input[@"priority"] integerValue];
        if (![store saveReminder:reminder commit:YES error:error]) return nil;
        return ReminderJSON(reminder);
    }

    if ([action isEqualToString:@"set_completed"]) {
        EKReminder *reminder = ReminderFromInput(input, store, error);
        if (reminder == nil) return nil;
        if (![input[@"completed"] isKindOfClass:NSNumber.class]) {
            if (error) *error = MakeError(@"completed must be true or false.");
            return nil;
        }
        reminder.completed = [input[@"completed"] boolValue];
        if (![store saveReminder:reminder commit:YES error:error]) return nil;
        return ReminderJSON(reminder);
    }

    if ([action isEqualToString:@"delete_reminder"]) {
        if (![input[@"confirm"] boolValue]) {
            if (error) *error = MakeError(@"Deletion requires confirm=true.");
            return nil;
        }
        EKReminder *reminder = ReminderFromInput(input, store, error);
        if (reminder == nil) return nil;
        NSDictionary *deleted = ReminderJSON(reminder);
        if (![store removeReminder:reminder commit:YES error:error]) return nil;
        return deleted;
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
        NSError *error = nil;
        NSData *inputData = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        NSDictionary *input = [NSJSONSerialization JSONObjectWithData:inputData options:0 error:&error];
        if (![input isKindOfClass:NSDictionary.class] || ![input[@"action"] isKindOfClass:NSString.class]) {
            WriteJSON(@{@"ok": @NO, @"error": error.localizedDescription ?: @"Expected a JSON object containing an action."});
            return 1;
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
}
