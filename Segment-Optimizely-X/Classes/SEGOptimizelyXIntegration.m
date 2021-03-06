//
//  SEGOptimizelyXIntegration.m
//  Pods
//
//  Created by ladan nasserian on 8/17/17.
//
//

#import "SEGOptimizelyXIntegration.h"
#if defined(__has_include) && __has_include(<Analytics/SEGAnalytics.h>)
#import <Analytics/SEGAnalytics.h>
#import <Analytics/SEGIntegration.h>
#import <Analytics/SEGAnalyticsUtils.h>
#else
#import <Segment/SEGAnalytics.h>
#import <Segment/SEGIntegration.h>
#import <Segment/SEGAnalyticsUtils.h>
#endif

@implementation SEGOptimizelyXIntegration

#pragma mark - Initialization

- (instancetype)initWithSettings:(NSDictionary *)settings andOptimizelyManager:(OPTLYManager *)manager withAnalytics:(SEGAnalytics *)analytics
{
    if (self = [super init]) {
        self.settings = settings;
        self.manager = manager;
        self.analytics = analytics;
        self.backgroundQueue = dispatch_queue_create("com.segment.integrations.optimizelyx.backgroundQueue", NULL);
    }

    if ([(NSNumber *)[self.settings objectForKey:@"listen"] boolValue]) {
        self.observer = [[NSNotificationCenter defaultCenter] addObserverForName:OptimizelyDidActivateExperimentNotification
                                                                          object:nil
                                                                           queue:nil
                                                                      usingBlock:^(NSNotification *_Nonnull note) {
                                                                          [self experimentDidGetViewed:note];
                                                                      }];
    }

    return self;
}


- (void)identify:(SEGIdentifyPayload *)payload
{
    if (payload.userId) {
        self.userId = payload.userId;
        SEGLog(@"SEGOptimizelyX assigning userId %@", self.userId);
    }

    if (payload.traits) {
        self.userTraits = payload.traits;
        SEGLog(@"SEGOptimizelyX assigning attributes %@", self.userTraits);
    }
}


- (void)track:(SEGTrackPayload *)payload
{
    if ([self.manager getOptimizely] == nil) {
        [self enqueueAction:payload];
        return;
    }

    [self trackEvent:payload];
}

- (void)reset
{
    if ([self.manager getOptimizely] == nil) {
        return;
    } else {
        [[NSNotificationCenter defaultCenter] removeObserver:self.observer];
        SEGLog(@"[NSNotificationCenter defaultCenter] removeObserver:%@", self.observer);
    }
}

#pragma mark - Real Track Event

- (void)trackEvent:(SEGTrackPayload *)payload
{
    OPTLYClient *client = [self.manager getOptimizely];

    // Segment will default sending `track` calls with `anonymousId`s since Optimizely X does not alias known and unknown users
    // https://developers.optimizely.com/x/solutions/sdks/reference/index.html?language=objectivec&platform=mobile#user-ids
    BOOL trackKnownUsers = [[self.settings objectForKey:@"trackKnownUsers"] boolValue];
    if (trackKnownUsers && [self.userId length] == 0) {
        SEGLog(@"Segment will only track users associated with a userId when the trackKnownUsers setting is enabled.");
        return;
    }

    // Attributes must not be nil, so Segment will trigger track without attributes if self.userTraits is empty
    if (trackKnownUsers) {
        if (self.userTraits.count > 0) {
            [client track:payload.event userId:self.userId attributes:self.userTraits eventTags:payload.properties];
            SEGLog(@"[optimizely track:%@ userId:%@ attributes:%@ eventTags:%@]", payload.event, self.userId, self.userTraits, payload.properties);
        } else {
            [client track:payload.event userId:self.userId eventTags:payload.properties];
            SEGLog(@"[optimizely track:%@ userId:%@ eventTags:%@]", payload.event, self.userId, payload.properties);
        }
    }

    NSString *segmentAnonymousId = [self.analytics getAnonymousId];
    if (!trackKnownUsers && self.userTraits.count > 0) {
        [client track:payload.event userId:segmentAnonymousId attributes:self.userTraits eventTags:payload.properties];
        SEGLog(@"[optimizely track:%@ userId:%@ attributes:%@ eventTags:%@]", payload.event, segmentAnonymousId, self.userTraits, payload.properties);
    } else {
        [client track:payload.event userId:segmentAnonymousId eventTags:payload.properties];
        SEGLog(@"[optimizely track:%@ userId:%@ eventTags:%@]", payload.event, segmentAnonymousId, payload.properties);
    }
}

#pragma mark - Experiment Viewed

- (void)experimentDidGetViewed:(NSNotification *)notification
{
    OPTLYExperiment *experiment = notification.userInfo[OptimizelyNotificationsUserDictionaryExperimentKey];
    OPTLYVariation *variation = notification.userInfo[OptimizelyNotificationsUserDictionaryVariationKey];

    NSMutableDictionary *properties = [[NSMutableDictionary alloc] init];
    properties[@"experimentId"] = [experiment experimentId];
    properties[@"experimentName"] = [experiment experimentKey];
    properties[@"variationId"] = [variation variationId];
    properties[@"variationName"] = [variation variationKey];

    if ([(NSNumber *)[self.settings objectForKey:@"nonInteraction"] boolValue]) {
        properties[@"nonInteraction"] = @1;
    }

    // Trigger event as per our spec https://segment.com/docs/spec/ab-testing/
    [self.analytics track:@"Experiment Viewed" properties:properties options:@{
        @"integrations" : @{
            @"Optimizely X" : @NO
        }
    }];
}

#pragma mark - Private - Queueing

- (void)enqueueAction:(SEGTrackPayload *)payload
{
    [self dispatchBackground:^{
        SEGLog(@"%@ Optimizely not initialized. Enqueueing action: %@", self, payload);
        @try {
            if (self.queue.count > 100) {
                // Remove the oldest element.
                [self.queue removeObjectAtIndex:0];
                SEGLog(@"%@ removeObjectAtIndex: 0", self.queue);
            }
            [self setupTimer];
            [self.queue addObject:payload];
            SEGLog(@"SEGOptimizelyX background queue length %i", self.queue.count);
        }
        @catch (NSException *exception) {
            SEGLog(@"%@ Error writing payload: %@", self, exception);
        }
    }];
}

- (NSMutableArray *)queue
{
    if (!_queue) {
        _queue = [NSMutableArray arrayWithCapacity:0];
    }

    return _queue;
}

- (void)setupTimer
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_flushTimer == nil) {
            _flushTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(isOptimizelyInitialized) userInfo:nil repeats:YES];
        }
    });
}

- (void)flushQueue
{
    for (SEGTrackPayload *obj in self.queue) {
        [self trackEvent:obj];
        SEGLog(@"SEGOptimizelyX calling track with payload:%@", obj);
    }

    [self.queue removeAllObjects];
    SEGLog(@"SEGOptimizelyX removing all objects from queue");
}

- (void)isOptimizelyInitialized
{
    [self dispatchBackground:^{

        if ([self.manager getOptimizely] == nil) {
            SEGLog(@"Optimizely not initialized.");
        } else {
            [self.flushTimer invalidate];
            self.flushTimer = nil;
            [self flushQueue];
            SEGLog(@"Optimizely initialized.");
        }

    }];
}

- (void)dispatchBackground:(void (^)(void))block
{
    dispatch_async(_backgroundQueue, block);
}


@end

@implementation OPTLYManager(SegmentOptimizelyX)
+ (OPTLYManager *)instanceWithBuilderBlock:(OPTLYManagerBuilderBlock)builderBlock {
    return [OPTLYManager init:builderBlock];
}
@end
