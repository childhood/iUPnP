//
//  UPnPControlPoint.m
//  iUPnPTestPrj
//
//  Created by Hao Hu on 26.08.11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "UPnPControlPoint.h"
#import "NSError+UPnP.h"
#import "EventParser.h"

//#define DEBUG_THREAD

//==================================ControlPoint private methods=========================================
@interface UPnPControlPoint() 


@end
//========================================================================================================

@implementation UPnPControlPoint

@synthesize devices = _devices,deviceIDSet,clientHandle,lastError,delegate;


//Callback function for the client.
//=====================================Functions forward declaration=====================================
int upnp_callback_func(Upnp_EventType, void *, void *);
void handle_discovery_message(void*);
void handle_byebye_message(void*);
void handle_event_received(void*);
//=======================================================================================================
id refToSelf = nil;


- (id) init
{
    self = [super init];
    if (self)
    {
        refToSelf = self;
        [self initWithHostAddress:nil andPort:0];
    }
    return self;
}




-(void) fireErrorEvent:(int) upnpError
{
    NSError* error = [[[NSError alloc] initWithUPnPError:upnpError] autorelease];
    if (delegate)
        [delegate errorDidReceive:error];
}

-(UPnPDevice*) getUPnPDeviceById:(NSString*) deviceID
{

    UPnPDevice* deviceToReturn = [[[_devices objectForKey:deviceID] retain]autorelease];
    return deviceToReturn;
}


-(id) initWithHostAddress:(NSString *)address andPort:(UInt16)port
{
    self = [super init];
    refToSelf = self;
    if (self)
    {
        int ret = UpnpInit([address cStringUsingEncoding:NSASCIIStringEncoding], port);
        if (ret != UPNP_E_SUCCESS)
        {
            NSLog(@"Cannot init the UPnP Stack");
            [self fireErrorEvent:ret];
        }
        else
        {
            ret = UpnpRegisterClient(upnp_callback_func, nil, &clientHandle);
            if (ret != UPNP_E_SUCCESS)
            {
                NSLog(@"Cannot Register Client");
                [self fireErrorEvent:ret];
            }
        }
        
        //====================================Init some iVars===============================================
        _devices = [[NSMutableDictionary alloc] init];
        _globalLock =[[NSLock alloc] init];
        deviceIDSet = [[NSMutableSet alloc] init];
        subscriptions = [[NSMutableDictionary alloc] initWithCapacity:5];
        eventParserQueue = dispatch_queue_create("de.haohu.iupnp.eventparser", NULL);
        //==================================================================================================
    }
    return self;
}



//Callback function for the client.
int upnp_callback_func(Upnp_EventType eventType, void *event, void *cookie)
{
    NSLock* lock = [refToSelf globalLock];
    [lock lock];
    NSAutoreleasePool *pool =[[NSAutoreleasePool alloc] init];
#ifdef DEBUG_THREAD
    static int idForThread = 0;
    NSThread* thread = [NSThread currentThread];
    NSString* threadName = [thread name];
    if (threadName == nil)
    {
        idForThread++;
        [thread setName:[NSString stringWithFormat:@"ID:%d",idForThread]];
    }
    NSLog(@"Thread name is %@",[thread name]);
#endif
    
    
    switch(eventType)
    {
        case UPNP_DISCOVERY_SEARCH_RESULT:
        case UPNP_DISCOVERY_ADVERTISEMENT_ALIVE:
        {
            handle_discovery_message(event);
            break;
        }
        case UPNP_DISCOVERY_SEARCH_TIMEOUT:
        {
            NSLog(@"Timeout.");
            [[refToSelf delegate] searchDidTimeout];
            break;
        }
        case UPNP_DISCOVERY_ADVERTISEMENT_BYEBYE:
        {
            handle_byebye_message(event);           
            break;
        }
            
        case UPNP_EVENT_RECEIVED:
        {
            
            break;
        }
        default:
        {
            NSLog(@"Unknown eventType");
            break;
        }
    }
    [pool drain];
    [lock unlock];
    return UPNP_E_SUCCESS;
}

//=================================Handle different callback functions==========================================
#pragma Callback function different handle
void handle_discovery_message(void* event)
{

    struct Upnp_Discovery *discovery = (struct Upnp_Discovery*) event;

    NSString *deviceID = [NSString stringWithCString:discovery->DeviceId encoding:NSUTF8StringEncoding];
  
    if ([[refToSelf deviceIDSet] containsObject:deviceID])
    {
       // NSLog(@"Device is in, ignore.");
        return;
    }
    else
    {
        [[refToSelf deviceIDSet] addObject:deviceID];
    }
    NSString* locationURL = [[NSString alloc] initWithCString:discovery->Location encoding:NSUTF8StringEncoding];
    UPnPDevice *device = [[UPnPDevice alloc] initWithLocationURL:locationURL timeout:4.0];
    [locationURL release];
    device.controlPointHandle = [refToSelf clientHandle];
    device.UDN = deviceID;
    device.delegate = refToSelf;
    [[refToSelf devices] setObject:device forKey:device.UDN];
    [device release];
    __block  UPnPDevice *tempDevice = device;
    dispatch_queue_t queue = dispatch_get_global_queue(0, 0);
    NSLog(@"%@ will in the Queue",tempDevice.UDN);
    dispatch_async(queue, ^{
        [tempDevice startParsing];
    });

}

void handle_byebye_message(void* event)
{
    struct Upnp_Discovery* discovery = (struct Upnp_Discovery*) event;
    NSString* deviceId = [NSString stringWithCString:discovery->DeviceId encoding:NSUTF8StringEncoding];
    UPnPDevice* upnpDevice = [[[[refToSelf devices] objectForKey:deviceId] retain] autorelease];
    [[refToSelf devices] removeObjectForKey:deviceId];
    [[refToSelf deviceIDSet] removeObject:deviceId];
    [[refToSelf delegate] upnpDeviceDidLeave:upnpDevice];
    
}

void handle_event_received(void* event)
{
    struct Upnp_Event* upnpEvent = (struct Upnp_Event*) event;
    char* ssid = upnpEvent->Sid;
    int eventKey = upnpEvent->EventKey;
    IXML_Document* doc = upnpEvent->ChangedVariables;
    NSString* strSSID = [NSString stringWithCString:ssid encoding:NSUTF8StringEncoding];
    NSString* xmlDocString = [[NSString alloc] initWithCString:ixmlDocumenttoString(doc) encoding:NSUTF8StringEncoding];
    EventParser* eventParser = [[EventParser alloc] initWithXMLString:xmlDocString];
    [eventParser parse];
    NSDictionary* varValueDict =[eventParser.varValueDict retain];
    [xmlDocString release];
    [eventParser release];
    [varValueDict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [[refToSelf delegate] eventNotifyDidReceiveWithSSID:strSSID eventKey:eventKey varName:key value:obj];
    }];
    
    
}
//================================================================================================================================

-(void) searchTarget:(NSString*) target withMx:(NSUInteger) mx
{
    UpnpSearchAsync(clientHandle, mx, [target cStringUsingEncoding:NSUTF8StringEncoding], NULL);
}


-(void) stop
{
    if (clientHandle != -1)
    {
        UpnpUnRegisterClient(clientHandle);
        UpnpFinish();
        clientHandle = -1;
    }
}


-(BOOL) subscribeService:(UPnPService*) service
{
    return [self subscribeService:service withTimeout:UPNP_INFINITE];;
}

-(BOOL) subscribeService:(UPnPService *)service withTimeout:(NSInteger) timeout
{
    const char* subsURL = [service.eventSubURL UTF8String];
    Upnp_SID ssid;
    if (timeout == UPNP_INFINITE)
    {
        timeout = -1;
    }
    int ret = UpnpSubscribe(self.clientHandle, subsURL, &timeout, ssid);
    
    if (ret == UPNP_E_SUCCESS)
    {
        NSString* ssidAsKey = [[NSString alloc] initWithCString:ssid encoding:NSUTF8StringEncoding];
        NSNumber* timeoutAsVal = [[NSNumber alloc] initWithInt:timeout];
        [subscriptions setObject:timeoutAsVal forKey:ssidAsKey];
        [timeoutAsVal release];
        [ssidAsKey release];
        return YES;
    }
    else
    {
        NSError* temp = [[NSError alloc] initWithUPnPError:ret];
        self.lastError = temp;
        [temp release];
        return NO;
    }
}

-(NSLock*) globalLock
{
    return _globalLock;
}


#pragma UPnPDevice callback
-(void) upnpDeviceDidFinishParsing:(UPnPDevice*) upnpDevice
{
    NSLog(@"%@ Finish parsing.", upnpDevice.UDN);
    UPnPDevice* upnpDeviceRet = [[upnpDevice retain] autorelease];
    [delegate upnpDeviceDidAdd:upnpDeviceRet];
    [upnpDevice release];
}

-(void) upnpDeviceDidReceiveError:(UPnPDevice*)  withError:(NSError*) error;
{
    
}

-(void) eventParser:(EventParser*) parser didFinishWithResult:(NSDictionary*) varValues
{
    
}

-(void) dealloc
{
    NSLog(@"UPnPControlPoint dealloc.");
    dispatch_release(eventParserQueue);
    [subscriptions release];
    [deviceIDSet release];
    [_globalLock release];
    [_devices release];
    [super dealloc];
}
@end
